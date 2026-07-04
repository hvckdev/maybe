# frozen_string_literal: true

class TinkoffItem::Importer
  include SyncStats::Collector
  include TinkoffAccount::DataHelpers

  attr_reader :tinkoff_item, :tinkoff_provider, :sync

  def initialize(tinkoff_item, tinkoff_provider:, sync: nil)
    @tinkoff_item = tinkoff_item
    @tinkoff_provider = tinkoff_provider
    @sync = sync
  end

  class CredentialsError < StandardError; end

  ACCOUNT_TYPE_MAP = {
    "Checking"  => "Depository",
    "Current"   => "Depository",
    "Debit"     => "Depository",
    "Credit"    => "CreditCard",
    "CreditCard" => "CreditCard",
    "Savings"   => "Depository",
    "Deposit"   => "Depository"
  }.freeze

  def import
    Rails.logger.info "TinkoffItem::Importer - Starting import for item #{tinkoff_item.id}"

    credentials = tinkoff_item.tinkoff_credentials
    unless credentials
      raise CredentialsError, "No Tinkoff credentials configured for item #{tinkoff_item.id}"
    end

    # Step 1: Fetch and store all accounts
    import_accounts

    # Step 2: For LINKED accounts only, fetch transaction data
    # Unlinked accounts just need basic info (name, balance) for the setup modal
    linked_accounts = TinkoffAccount
      .where(tinkoff_item_id: tinkoff_item.id)
      .joins(:account_provider)

    Rails.logger.info "TinkoffItem::Importer - Found #{linked_accounts.count} linked accounts to process"

    linked_accounts.each do |tinkoff_account|
      Rails.logger.info "TinkoffItem::Importer - Processing linked account #{tinkoff_account.id}"
      import_transactions(tinkoff_account)
    end

    # Update raw payload on the item
    tinkoff_item.upsert_tinkoff_snapshot!(stats)
  rescue Provider::Tinkoff::AuthenticationError => e
    Rails.logger.error "TinkoffItem::Importer - Authentication error for item #{tinkoff_item.id}: #{e.message}"
    tinkoff_item.update!(status: :requires_update)
    raise
  end

  private

    def stats
      @stats ||= {}
    end

    def persist_stats!
      return unless sync&.respond_to?(:sync_stats)
      merged = (sync.sync_stats || {}).merge(stats)
      sync.update_columns(sync_stats: merged)
    end

    def import_accounts
      Rails.logger.info "TinkoffItem::Importer - Fetching accounts"

      accounts_data = tinkoff_provider.list_accounts
      stats["api_requests"] = stats.fetch("api_requests", 0) + 1

      # Normalize response: handle both { accounts: [...] } and bare array
      accounts_list = if accounts_data.is_a?(Hash)
        accounts_data[:accounts] || accounts_data["accounts"] || []
      else
        Array(accounts_data)
      end

      stats["total_accounts"] = accounts_list.size

      # Track upstream account IDs to detect removed accounts
      upstream_account_ids = []

      accounts_list.each do |account_data|
        begin
          account_hash = sdk_object_to_hash(account_data)
          tinkoff_account = import_account(account_hash)
          upstream_account_ids << tinkoff_account.tinkoff_account_id if tinkoff_account&.tinkoff_account_id.present?
        rescue => e
          Rails.logger.error "TinkoffItem::Importer - Failed to import account: #{e.message}"
          stats["accounts_skipped"] = stats.fetch("accounts_skipped", 0) + 1
          register_error(e, account_data: account_data)
        end
      end

      persist_stats!

      # Clean up accounts that no longer exist upstream
      prune_removed_accounts(upstream_account_ids)
    end

    def import_account(account_data)
      data = account_data.with_indifferent_access

      # Extract account ID
      tinkoff_account_id = (data[:id] || data[:accountId]).to_s
      return nil if tinkoff_account_id.blank?

      # Find or initialize the TinkoffAccount record
      tinkoff_account = tinkoff_item.tinkoff_accounts.find_or_initialize_by(
        tinkoff_account_id: tinkoff_account_id
      )

      # Parse balance from nested balance object or flat amount field
      balance = parse_balance(data)
      currency = "RUB"

      # Map account type from Tinkoff's format to app's format
      raw_type = data[:accountType] || data[:account_type] || data[:type] || "Depository"
      mapped_type = ACCOUNT_TYPE_MAP[raw_type] || "Depository"

      # Parse credit limit for credit cards
      credit_limit = parse_decimal(data[:creditLimit] || data[:credit_limit])

      tinkoff_account.assign_attributes(
        name: data[:name] || data[:accountName] || "Tinkoff Account",
        current_balance: balance,
        currency: currency,
        account_type: mapped_type,
        account_status: data[:status] || data[:accountStatus],
        raw_payload: account_data
      )

      # Persist institution metadata if present at the item level
      unless tinkoff_account.institution_metadata.present?
        tinkoff_account.institution_metadata = {
          name: tinkoff_item.institution_name,
          logo: nil,
          domain: tinkoff_item.institution_domain
        }.compact
      end

      tinkoff_account.save!

      stats["accounts_imported"] = stats.fetch("accounts_imported", 0) + 1

      tinkoff_account
    end

    def import_transactions(tinkoff_account)
      Rails.logger.info "TinkoffItem::Importer - Fetching transactions for account #{tinkoff_account.id}"

      begin
        start_date = calculate_transaction_start_date(tinkoff_account)
        end_date = Date.current

        transactions_data = tinkoff_provider.get_transactions(
          account_id: tinkoff_account.tinkoff_account_id,
          start_date: start_date,
          end_date: end_date
        )

        stats["api_requests"] = stats.fetch("api_requests", 0) + 1

        # Normalize response: handle both { payload: [...] } and bare array
        transactions_list = if transactions_data.is_a?(Hash)
          transactions_data[:payload] || transactions_data["payload"] ||
            transactions_data[:operations] || transactions_data["operations"] ||
            transactions_data[:transactions] || transactions_data["transactions"] || []
        else
          Array(transactions_data)
        end

        if transactions_list.any?
          # Convert SDK objects to hashes and merge with existing
          transactions_hashes = transactions_list.map { |t| sdk_object_to_hash(t) }
          merged = merge_transactions(tinkoff_account.raw_transactions_payload || [], transactions_hashes)
          tinkoff_account.upsert_tinkoff_transactions_snapshot!(merged)
          stats["transactions_found"] = stats.fetch("transactions_found", 0) + transactions_data.size
        end
      rescue => e
        Rails.logger.warn "TinkoffItem::Importer - Failed to fetch transactions for account #{tinkoff_account.id}: #{e.message}"
        register_error(e, context: "transactions", account_id: tinkoff_account.id)
      end
    end

    def calculate_transaction_start_date(tinkoff_account)
      # Use user-specified start date if available
      user_start = tinkoff_account.sync_start_date
      return user_start if user_start.present?

      # For accounts with existing transactions, use incremental sync
      existing_count = (tinkoff_account.raw_transactions_payload || []).size
      if existing_count >= 10 && tinkoff_item.last_synced_at.present?
        # Incremental: go back 7 days from last sync to catch updates
        (tinkoff_item.last_synced_at - 7.days).to_date
      else
        # Full sync: go back 90 days
        90.days.ago.to_date
      end
    end

    def parse_balance(data)
      balance_data = data[:balance]

      if balance_data.is_a?(Hash)
        parse_decimal(balance_data[:amount] || balance_data["amount"])
      else
        parse_decimal(balance_data)
      end
    end

    def merge_transactions(existing, new_transactions)
      # Merge by operation ID, preferring newer data
      by_id = {}
      existing.each { |t| by_id[transaction_key(t)] = t }
      new_transactions.each { |t| by_id[transaction_key(t)] = t }
      by_id.values
    end

    def transaction_key(transaction)
      transaction = transaction.with_indifferent_access if transaction.is_a?(Hash)
      # Use ID if available, otherwise generate key from date/amount/description
      transaction[:id] || transaction["id"] ||
        [ transaction[:date], transaction[:amount], transaction[:description] ].join("-")
    end

    def prune_removed_accounts(upstream_account_ids)
      return if upstream_account_ids.empty?

      # Find accounts that exist locally but not upstream
      removed = tinkoff_item.tinkoff_accounts
        .where.not(tinkoff_account_id: upstream_account_ids)

      if removed.any?
        Rails.logger.info "TinkoffItem::Importer - Pruning #{removed.count} removed accounts"
        removed.destroy_all
      end
    end

    def register_error(error, **context)
      stats["errors"] ||= []
      stats["errors"] << {
        message: error.message,
        context: context.to_s,
        timestamp: Time.current.iso8601
      }
    end
end
