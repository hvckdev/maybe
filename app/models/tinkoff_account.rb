# frozen_string_literal: true

class TinkoffAccount < ApplicationRecord
  include CurrencyNormalizable
  include TinkoffAccount::DataHelpers

  belongs_to :tinkoff_item

  encrypts :raw_transactions_payload, deterministic: true

  # Association through account_providers
  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account
  has_one :linked_account, through: :account_provider, source: :account

  validates :name, :currency, presence: true

  # Scopes
  scope :with_linked, -> { joins(:account_provider) }
  scope :without_linked, -> { left_joins(:account_provider).where(account_providers: { id: nil }) }
  scope :ordered, -> { order(created_at: :desc) }

  # Callbacks
  after_destroy :enqueue_connection_cleanup

  # Helper to get account using account_providers system
  def current_account
    account
  end

  # Idempotently create or update AccountProvider link
  # CRITICAL: After creation, reload association to avoid stale nil
  def ensure_account_provider!(linked_account)
    return nil unless linked_account

    provider = account_provider || build_account_provider
    provider.account = linked_account
    provider.save!

    # Reload to clear cached nil value
    reload_account_provider
    account_provider
  end

  def upsert_from_tinkoff!(account_data)
    # Convert SDK object to hash if needed
    data = sdk_object_to_hash(account_data).with_indifferent_access

    update!(
      tinkoff_account_id: (data[:id] || data[:accountId] || data[:account_id])&.to_s,
      name: data[:name] || data[:accountName] || data[:account_name],
      current_balance: parse_balance_from_data(data),
      currency: extract_currency(data, fallback: "RUB"),
      account_status: data[:status] || data[:accountStatus],
      account_type: data[:accountType] || data[:account_type] || data[:type],
      institution_metadata: extract_institution_metadata(data),
      raw_payload: account_data
    )
  end

  # Store raw transaction data snapshot (dedup handled by importer)
  def upsert_tinkoff_transactions_snapshot!(transactions_snapshot)
    assign_attributes(
      raw_transactions_payload: transactions_snapshot
    )

    save!
  end

  # Store raw account data snapshot
  def upsert_tinkoff_snapshot!(accounts_snapshot)
    assign_attributes(
      raw_payload: accounts_snapshot
    )

    save!
  end

  private

    def parse_balance_from_data(data)
      balance_data = data[:balance]

      if balance_data.is_a?(Hash)
        parse_decimal(balance_data[:amount] || balance_data["amount"])
      else
        parse_decimal(balance_data)
      end
    end

    def extract_institution_metadata(data)
      {
        name: data[:institution_name] || data.dig(:institution, :name),
        logo: data[:institution_logo] || data.dig(:institution, :logo),
        domain: data[:institution_domain] || data.dig(:institution, :domain)
      }.compact
    end

    def enqueue_connection_cleanup
      return unless tinkoff_item

      TinkoffConnectionCleanupJob.perform_later(
        tinkoff_item_id: tinkoff_item.id,
        account_id: id
      )
    end

    def log_invalid_currency(currency_value)
      Rails.logger.warn("Invalid currency code '#{currency_value}' for Tinkoff account #{id}, defaulting to RUB")
    end
end
