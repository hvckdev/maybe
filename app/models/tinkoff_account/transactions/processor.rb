# frozen_string_literal: true

class TinkoffAccount::Transactions::Processor
  include TinkoffAccount::DataHelpers

  attr_reader :tinkoff_account

  def initialize(tinkoff_account)
    @tinkoff_account = tinkoff_account
  end

  def process
    unless tinkoff_account.raw_transactions_payload.present?
      Rails.logger.info "TinkoffAccount::Transactions::Processor - No transactions in raw_transactions_payload for tinkoff_account #{tinkoff_account.id}"
      return { success: true, total: 0, imported: 0, failed: 0, errors: [] }
    end

    total_count = tinkoff_account.raw_transactions_payload.count
    Rails.logger.info "TinkoffAccount::Transactions::Processor - Processing #{total_count} transactions for tinkoff_account #{tinkoff_account.id}"

    imported_count = 0
    failed_count = 0
    errors = []

    # Each entry is processed inside a transaction, but to avoid locking up the DB when
    # there are hundreds or thousands of transactions, we process them individually.
    tinkoff_account.raw_transactions_payload.each_with_index do |transaction_data, index|
      begin
        result = process_transaction(transaction_data)

        if result.nil?
          # Transaction was skipped (e.g., no linked account or blank external_id)
          failed_count += 1
          transaction_id = transaction_data.try(:[], :id) || transaction_data.try(:[], "id") || "unknown"
          errors << { index: index, transaction_id: transaction_id, error: "Skipped" }
        else
          imported_count += 1
        end
      rescue ArgumentError => e
        # Validation error - log and continue
        failed_count += 1
        transaction_id = transaction_data.try(:[], :id) || transaction_data.try(:[], "id") || "unknown"
        error_message = "Validation error: #{e.message}"
        Rails.logger.error "TinkoffAccount::Transactions::Processor - #{error_message} (transaction #{transaction_id})"
        errors << { index: index, transaction_id: transaction_id, error: error_message }
      rescue => e
        # Unexpected error - log with full context and continue
        failed_count += 1
        transaction_id = transaction_data.try(:[], :id) || transaction_data.try(:[], "id") || "unknown"
        error_message = "#{e.class}: #{e.message}"
        Rails.logger.error "TinkoffAccount::Transactions::Processor - Error processing transaction #{transaction_id}: #{error_message}"
        Rails.logger.error e.backtrace.join("\n")
        errors << { index: index, transaction_id: transaction_id, error: error_message }
      end
    end

    result = {
      success: failed_count == 0,
      total: total_count,
      imported: imported_count,
      failed: failed_count,
      errors: errors
    }

    if failed_count > 0
      Rails.logger.warn "TinkoffAccount::Transactions::Processor - Completed with #{failed_count} failures out of #{total_count} transactions"
    else
      Rails.logger.info "TinkoffAccount::Transactions::Processor - Successfully processed #{imported_count} transactions"
    end

    result
  end

  private

    def account
      @tinkoff_account.current_account
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def process_transaction(transaction_data)
      return nil unless account.present?

      data = transaction_data.with_indifferent_access

      # Extract operation ID as external_id
      external_id = (data[:id] || data[:operationId] || data[:operation_id]).to_s
      return nil if external_id.blank?

      # Parse transaction amount
      amount = parse_decimal(data[:amount])
      return nil if amount.nil?

      # Tinkoff sign convention: negative = debit (money out), positive = credit (money in).
      # App convention: positive = money out, negative = money in.
      # So we negate the amount.
      amount = -amount

      # Parse date from ISO8601 timestamp or date string
      date = parse_date(data[:date] || data[:transactionDate] || data[:timestamp])
      return nil if date.nil?

      # Extract name: prefer merchant payment name, fall back to description
      name = data.dig(:payment, :name) || data[:paymentName] || data[:description] || data[:merchantName] || "Transaction"

      # Tinkoff always uses RUB
      currency = "RUB"

      # Build provider-specific metadata for transaction.extra
      extra = build_extra_metadata(data)

      Rails.logger.debug "TinkoffAccount::Transactions::Processor - Importing transaction: id=#{external_id} amount=#{amount} date=#{date} name=#{name.truncate(50)}"

      # Use ProviderImportAdapter for proper deduplication via external_id + source
      import_adapter.import_transaction(
        external_id: external_id,
        amount: amount,
        currency: currency,
        date: date,
        name: name[0..254], # Limit to 255 chars
        source: "tinkoff",
        extra: extra
      )
    end

    def build_extra_metadata(data)
      {
        "tinkoff" => {
          "id" => data[:id] || data[:operationId],
          "category_id" => data[:categoryId],
          "status" => data[:status],
          "payment" => data[:payment].is_a?(Hash) ? data[:payment] : nil
        }.compact
      }
    end
end
