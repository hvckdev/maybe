# frozen_string_literal: true

# Creates a manual ledger transaction through the same Entry + Transaction path
# used by the API. Every write requires an exact, user-confirmed preview token.
class Assistant::Function::CreateTransaction < Assistant::Function
  CONFIRMATION_TTL = 15.minutes

  class << self
    def name
      "create_transaction"
    end

    def description
      <<~INSTRUCTIONS
        Previews and, only after explicit user confirmation, creates one manual transaction.

        Use get_accounts to get a writable account_id and get_categories, get_merchants,
        or get_tags before referencing related ids. An expense is money spent and an
        income is money received. Pass a positive amount with transaction_type set to
        "expense" or "income". The legacy type aliases "inflow" and "outflow" are
        also accepted.

        Confirmation is a required two-step flow:
        1. Call without confirmation_token to get a preview and token. This never writes data.
        2. Show that preview to the user and ask for explicit confirmation. Only after they confirm,
           call again with the unchanged transaction details, the returned confirmation_token, and
           confirmed: true. Never create a transaction without that explicit confirmation.

        If external_id is provided, repeated confirmed calls with the same account, source,
        and external_id return the existing transaction instead of creating a duplicate.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: %w[account_id amount name],
      properties: {
        account_id: { type: "string", description: "Writable account ID from get_accounts." },
        amount: { type: "number", minimum: 0, description: "Non-negative transaction magnitude. Use transaction_type to specify its direction." },
        transaction_type: { type: "string", enum: %w[expense income], description: "expense for money spent; income for money received or a top-up." },
        type: { type: "string", enum: %w[expense income inflow outflow], description: "Legacy alias for transaction_type." },
        name: { type: "string", description: "Transaction name, payee, or description." },
        date: { type: "string", description: "Date in YYYY-MM-DD. Defaults to today." },
        currency: { type: "string", description: "ISO 4217 currency code. Defaults to the account currency." },
        category_id: { type: [ "string", "null" ], description: "Optional category ID from get_categories." },
        merchant_id: { type: [ "string", "null" ], description: "Optional merchant ID from get_merchants." },
        tag_ids: { type: "array", items: { type: "string" }, description: "Optional tag IDs from get_tags." },
        notes: { type: [ "string", "null" ], description: "Optional notes." },
        external_id: { type: "string", description: "Optional stable external identifier used to make confirmed imports idempotent." },
        source: { type: "string", description: "Provenance label paired with external_id. Defaults to mcp." },
        confirmation_token: { type: "string", description: "Token returned by the preview call." },
        confirmed: { type: "boolean", description: "Set to true only after the user explicitly confirms the preview." }
      }
    )
  end

  def call(params = {})
    attributes = transaction_attributes(params)
    return attributes if error_response?(attributes)

    token = params["confirmation_token"].to_s
    if params["confirmed"] == true && token.present?
      return create_confirmed_transaction(attributes, token)
    end

    preview_transaction(attributes)
  end

  private
    def transaction_attributes(params)
      account = writable_account(params["account_id"])
      return error("account_not_found", "No account found with that ID that this user can write to.") unless account

      amount = parse_amount(params["amount"])
      return amount if error_response?(amount)

      transaction_type = normalize_transaction_type(params["transaction_type"].presence || params["type"].presence)
      return transaction_type if error_response?(transaction_type)

      name = params["name"].to_s.strip
      return error("invalid_name", "name is required.") if name.blank?

      date = parse_date(params["date"])
      return date if error_response?(date)

      currency = (params["currency"].to_s.strip.presence || account.currency.presence || family.primary_currency_code).upcase
      return error("invalid_currency", "currency must be a valid ISO 4217 code.") unless valid_currency?(currency)

      entryable_attributes = resolve_entryable_attributes(params)
      return entryable_attributes if error_response?(entryable_attributes)

      external_id = params["external_id"].to_s.presence
      source = external_id ? (params["source"].to_s.strip.presence || "mcp") : nil

      {
        account: account,
        amount: amount,
        transaction_type: transaction_type,
        name: name,
        date: date,
        currency: currency,
        notes: params.key?("notes") ? params["notes"] : nil,
        entryable_attributes: entryable_attributes,
        external_id: external_id,
        source: source
      }
    end

    def writable_account(id)
      return nil unless valid_uuid?(id)

      family.accounts.writable_by(user).visible.find_by(id: id)
    end

    def parse_amount(value)
      return error("invalid_amount", "amount must be a finite number greater than or equal to zero.") if value.nil? || value.to_s.strip.empty?

      amount = BigDecimal(value.to_s)
      return error("invalid_amount", "amount must be a finite number greater than or equal to zero.") unless amount.finite? && amount >= 0

      amount
    rescue ArgumentError, TypeError
      error("invalid_amount", "amount must be a finite number greater than or equal to zero.")
    end

    def normalize_transaction_type(value)
      case value.to_s.downcase
      when "expense", "outflow" then "expense"
      when "income", "inflow" then "income"
      else error("invalid_transaction_type", "transaction_type must be either 'expense' or 'income'.")
      end
    end

    def parse_date(value)
      return Date.current if value.blank?

      Date.iso8601(value.to_s)
    rescue Date::Error
      error("invalid_date", "date must use the YYYY-MM-DD format.")
    end

    def resolve_entryable_attributes(params)
      attrs = { category_id: nil, merchant_id: nil, tag_ids: [] }

      if params.key?("category_id")
        category_id = optional_uuid(params["category_id"])
        return category_id if error_response?(category_id)
        return error("invalid_category", "category_id does not belong to the user's family.") if category_id && !family.categories.exists?(id: category_id)

        attrs[:category_id] = category_id
      end

      if params.key?("merchant_id")
        merchant_id = optional_uuid(params["merchant_id"])
        return merchant_id if error_response?(merchant_id)
        return error("invalid_merchant", "merchant_id is not available to the user's family.") if merchant_id && !available_merchants.exists?(id: merchant_id)

        attrs[:merchant_id] = merchant_id
      end

      if params.key?("tag_ids")
        tag_ids = Array(params["tag_ids"]).map(&:to_s).reject(&:blank?)
        return error("invalid_tags", "One or more tag_ids do not belong to the user's family.") unless valid_tag_ids?(tag_ids)

        attrs[:tag_ids] = tag_ids
      end

      attrs
    end

    def optional_uuid(value)
      return nil if value.nil? || value == ""
      return value.to_s if valid_uuid?(value)

      error("invalid_uuid", "Expected a valid UUID.")
    end

    def valid_tag_ids?(tag_ids)
      return true if tag_ids.empty?

      family.tags.where(id: tag_ids).count == tag_ids.uniq.size
    end

    def available_merchants
      family.available_merchants_for(user)
    end

    def valid_currency?(code)
      Money::Currency.new(code)
      true
    rescue Money::Currency::UnknownCurrencyError, ArgumentError
      false
    end

    def preview_transaction(attributes)
      token = SecureRandom.uuid
      Rails.cache.write(
        confirmation_cache_key(token),
        { user_id: user.id, fingerprint: fingerprint(attributes) },
        expires_in: CONFIRMATION_TTL
      )

      {
        success: false,
        confirmation_required: true,
        confirmation_token: token,
        transaction: serialize_attributes(attributes),
        message: "Show this preview to the user and request explicit confirmation before creating the transaction."
      }
    end

    def create_confirmed_transaction(attributes, token)
      confirmation = Rails.cache.read(confirmation_cache_key(token))
      unless valid_confirmation?(confirmation, attributes)
        return error("invalid_confirmation", "The confirmation token is invalid, expired, or does not match this transaction. Request a new preview and explicit confirmation.")
      end

      existing = attributes[:account].entries.find_by(idempotency_key: token)
      return success(existing, created: false) if existing

      if attributes[:external_id]
        existing = existing_idempotent_entry(attributes)
        return existing_response(existing) if existing
      end

      entry = attributes[:account].entries.new(
        name: attributes[:name],
        date: attributes[:date],
        amount: signed_amount(attributes),
        currency: attributes[:currency],
        notes: attributes[:notes],
        external_id: attributes[:external_id],
        source: attributes[:source],
        idempotency_key: token,
        entryable_type: "Transaction",
        entryable_attributes: attributes[:entryable_attributes]
      )

      Entry.transaction do
        entry.save!
        entry.lock_saved_attributes!
        entry.transaction.lock_attr!(:tag_ids) if entry.transaction.tags.any?
        entry.mark_user_modified!
      end

      sync_warning = sync_account(entry)
      Rails.cache.write(confirmation_cache_key(token), confirmation.merge(entry_id: entry.id), expires_in: CONFIRMATION_TTL)
      success(entry, created: true, warning: sync_warning)
    rescue ActiveRecord::RecordNotUnique
      existing = attributes[:account].entries.find_by(idempotency_key: token)
      existing ||= existing_idempotent_entry(attributes) if attributes[:external_id]
      return existing_response(existing) if existing && existing.idempotency_key != token
      return success(existing, created: false) if existing

      raise
    rescue ActiveRecord::RecordInvalid => e
      error("validation_failed", e.record.errors.full_messages.join("; "))
    end

    def sync_account(entry)
      entry.sync_account_later
      nil
    rescue StandardError => e
      "Transaction created, but the post-create account sync could not be enqueued (#{e.class}). The balance will recalculate on the next sync."
    end

    def valid_confirmation?(confirmation, attributes)
      return false unless confirmation.is_a?(Hash)

      confirmation.fetch(:user_id, confirmation["user_id"]) == user.id &&
        confirmation.fetch(:fingerprint, confirmation["fingerprint"]) == fingerprint(attributes)
    end

    def signed_amount(attributes)
      attributes[:transaction_type] == "income" ? -attributes[:amount] : attributes[:amount]
    end

    def fingerprint(attributes)
      Digest::SHA256.hexdigest([
        attributes[:account].id,
        attributes[:amount].to_s("F"),
        attributes[:transaction_type],
        attributes[:name],
        attributes[:date].iso8601,
        attributes[:currency],
        attributes[:notes],
        attributes.dig(:entryable_attributes, :category_id),
        attributes.dig(:entryable_attributes, :merchant_id),
        attributes.dig(:entryable_attributes, :tag_ids).sort,
        attributes[:external_id],
        attributes[:source]
      ].to_json)
    end

    def confirmation_cache_key(token)
      "assistant:create_transaction_confirmation:#{token}"
    end

    def existing_idempotent_entry(attributes)
      attributes[:account].entries.find_by(
        external_id: attributes[:external_id],
        source: attributes[:source]
      )
    end

    def existing_response(existing)
      return error("idempotency_conflict", "external_id already belongs to a non-transaction entry.") unless existing&.entryable&.is_a?(Transaction)

      success(existing, created: false, message: "Transaction already exists for this external_id; returned the existing one.")
    end

    def serialize_attributes(attributes)
      transaction = attributes[:entryable_attributes]
      {
        account: { id: attributes[:account].id, name: attributes[:account].name, currency: attributes[:currency] },
        name: attributes[:name],
        date: attributes[:date],
        amount: attributes[:amount].to_f,
        transaction_type: attributes[:transaction_type],
        signed_amount: signed_amount(attributes).to_f,
        currency: attributes[:currency],
        notes: attributes[:notes],
        category: related_preview(family.categories, transaction[:category_id]),
        merchant: related_preview(available_merchants, transaction[:merchant_id]),
        tags: family.tags.where(id: transaction[:tag_ids]).map { |tag| { id: tag.id, name: tag.name } },
        external_id: attributes[:external_id],
        source: attributes[:source]
      }
    end

    def related_preview(scope, id)
      record = id && scope.find_by(id: id)
      record && { id: record.id, name: record.respond_to?(:name_with_parent) ? record.name_with_parent : record.name }
    end

    def success(entry, created:, warning: nil, message: nil)
      transaction = entry.entryable
      return error("idempotency_conflict", "Idempotency key belongs to a non-transaction entry.") unless transaction.is_a?(Transaction)

      response = {
        success: true,
        created: created,
        transaction: serialize(transaction),
        message: message || (created ? "Transaction '#{entry.name}' created." : "Transaction already created; returned the existing one.")
      }
      response[:warning] = warning if warning
      response
    end

    def serialize(transaction)
      entry = transaction.entry
      {
        id: transaction.id,
        entry_id: entry.id,
        name: entry.name,
        date: entry.date,
        amount: entry.amount.to_f,
        amount_formatted: format_money(entry),
        currency: entry.currency,
        transaction_type: entry.classification,
        type: entry.classification,
        notes: entry.notes,
        category: transaction.category && { id: transaction.category.id, name: transaction.category.name_with_parent },
        merchant: transaction.merchant && { id: transaction.merchant.id, name: transaction.merchant.name },
        tags: transaction.tags.map { |tag| { id: tag.id, name: tag.name } }
      }
    end

    def format_money(entry)
      entry.amount_money.format
    rescue StandardError
      "#{entry.amount} #{entry.currency}"
    end

    def error_response?(value)
      value.is_a?(Hash) && value[:success] == false
    end

    def error(key, message)
      { success: false, error: key, message: message }
    end
end
