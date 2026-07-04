# frozen_string_literal: true

class TinkoffAccount::Processor
  include TinkoffAccount::DataHelpers

  attr_reader :tinkoff_account

  def initialize(tinkoff_account)
    @tinkoff_account = tinkoff_account
  end

  def process
    account = tinkoff_account.current_account
    return unless account

    Rails.logger.info "TinkoffAccount::Processor - Processing account #{tinkoff_account.id} -> Sure account #{account.id}"

    # Update account balance FIRST (before processing transactions)
    update_account_balance(account)

    # Process transactions
    transactions_count = tinkoff_account.raw_transactions_payload&.size || 0
    Rails.logger.info "TinkoffAccount::Processor - Transactions payload has #{transactions_count} items"

    if tinkoff_account.raw_transactions_payload.present?
      Rails.logger.info "TinkoffAccount::Processor - Processing transactions..."
      TinkoffAccount::Transactions::Processor.new(tinkoff_account).process
    else
      Rails.logger.warn "TinkoffAccount::Processor - No transactions payload to process"
    end

    # Trigger immediate UI refresh so entries appear in the activity feed
    account.broadcast_sync_complete
    Rails.logger.info "TinkoffAccount::Processor - Broadcast sync complete for account #{account.id}"

    { transactions_processed: transactions_count > 0 }
  end

  private

    def update_account_balance(account)
      # Get balance from provider data
      balance = tinkoff_account.current_balance || 0

      # Banking sign convention:
      # - CreditCard accounts: Tinkoff returns positive values for outstanding debt.
      #   In the app, CreditCard balance is positive for debt, so keep as-is.
      # - Loan accounts: similar to CreditCard.
      # - Depository accounts: positive = money in.
      if account.accountable_type == "CreditCard" || account.accountable_type == "Loan"
        balance = -balance
      end

      Rails.logger.info "TinkoffAccount::Processor - Balance update: #{balance}"

      # Tinkoff always deals in RUB
      currency = tinkoff_account.currency || "RUB"

      account.assign_attributes(
        balance: balance,
        cash_balance: balance,
        currency: currency
      )
      account.save!

      # Create or update the current balance anchor valuation for linked accounts
      # This is critical for reverse sync to work correctly
      account.set_current_balance(balance)
    end
end
