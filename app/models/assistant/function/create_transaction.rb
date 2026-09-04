class Assistant::Function::CreateTransaction < Assistant::Function
  CONFIRMATION_TTL = 15.minutes

  class << self
    def name
      "create_transaction"
    end

    def description
      <<~INSTRUCTIONS
        Previews and, only after explicit user confirmation, creates one manual transaction.

        Use get_accounts to get a writable account_id and get_categories to get a category_id.
        An expense is money spent and an income is money received (for example, a top-up).

        Confirmation is a required two-step flow:
        1. Call without confirmation_token to get a preview and token. This never writes data.
        2. Show that preview to the user and ask for explicit confirmation. Only after they confirm,
           call again with the unchanged transaction details, the returned confirmation_token, and
           confirmed: true. Never create a transaction without that explicit confirmation.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: %w[account_id amount transaction_type name],
      properties: {
        account_id: { type: "string", description: "Writable account ID from get_accounts." },
        amount: { type: "number", minimum: 0.01, description: "Positive transaction magnitude." },
        transaction_type: { type: "string", enum: %w[expense income], description: "expense for a spend; income for money received or a top-up." },
        name: { type: "string", description: "Transaction name." },
        date: { type: "string", description: "Date in YYYY-MM-DD. Defaults to today." },
        category_id: { type: [ "string", "null" ], description: "Optional category ID from get_categories." },
        notes: { type: [ "string", "null" ], description: "Optional notes." },
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
      return error("account_not_found", "Account with id '#{params["account_id"]}' was not found or is not writable.") unless account

      amount = parse_amount(params["amount"])
      return amount if error_response?(amount)

      transaction_type = params["transaction_type"].to_s
      unless transaction_type.in?(%w[expense income])
        return error("invalid_transaction_type", "transaction_type must be either 'expense' or 'income'.")
      end

      name = params["name"].to_s.strip
      return error("name_required", "Please provide a transaction name.") if name.blank?

      date = parse_date(params["date"])
      return date if error_response?(date)

      category = category_for(params["category_id"])
      return category if error_response?(category)

      {
        account: account,
        amount: amount,
        transaction_type: transaction_type,
        name: name,
        date: date,
        category: category,
        notes: params.key?("notes") ? params["notes"] : nil
      }
    end

    def writable_account(id)
      return nil unless valid_uuid?(id)

      family.accounts.writable_by(user).visible.find_by(id: id)
    end

    def parse_amount(value)
      amount = BigDecimal(value.to_s)
      return error("invalid_amount", "amount must be a finite number greater than zero.") unless amount.finite? && amount.positive?

      amount
    rescue ArgumentError
      error("invalid_amount", "amount must be a finite number greater than zero.")
    end

    def parse_date(value)
      return Date.current if value.blank?

      Date.iso8601(value.to_s)
    rescue Date::Error
      error("invalid_date", "date must use the YYYY-MM-DD format.")
    end

    def category_for(id)
      return nil if id.nil? || id == ""
      return error("invalid_category", "category_id must be a valid UUID.") unless valid_uuid?(id)

      family.categories.find_by(id: id) || error("invalid_category", "category_id does not belong to the user's family.")
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

      entry = attributes[:account].entries.find_by(idempotency_key: token)
      return success(entry) if entry

      entry = attributes[:account].entries.new(
        name: attributes[:name],
        date: attributes[:date],
        amount: signed_amount(attributes),
        currency: attributes[:account].currency,
        notes: attributes[:notes],
        idempotency_key: token,
        entryable: Transaction.new(category: attributes[:category])
      )

      Entry.transaction do
        entry.save!
        entry.lock_saved_attributes!
        entry.mark_user_modified!
        entry.sync_account_later
      end

      Rails.cache.write(confirmation_cache_key(token), confirmation.merge(entry_id: entry.id), expires_in: CONFIRMATION_TTL)
      success(entry)
    rescue ActiveRecord::RecordNotUnique
      success(attributes[:account].entries.find_by!(idempotency_key: token))
    rescue ActiveRecord::RecordInvalid => e
      error("validation_failed", e.record.errors.full_messages.join("; "))
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
        attributes[:category]&.id,
        attributes[:notes]
      ].to_json)
    end

    def confirmation_cache_key(token)
      "assistant:create_transaction_confirmation:#{token}"
    end

    def serialize_attributes(attributes)
      {
        account: { id: attributes[:account].id, name: attributes[:account].name, currency: attributes[:account].currency },
        name: attributes[:name],
        date: attributes[:date],
        amount: attributes[:amount].to_f,
        transaction_type: attributes[:transaction_type],
        signed_amount: signed_amount(attributes).to_f,
        currency: attributes[:account].currency,
        notes: attributes[:notes],
        category: attributes[:category] && { id: attributes[:category].id, name: attributes[:category].name_with_parent }
      }
    end

    def success(entry)
      transaction = entry.transaction
      {
        success: true,
        transaction: {
          id: transaction.id,
          entry_id: entry.id,
          name: entry.name,
          date: entry.date,
          amount: entry.amount.to_f,
          currency: entry.currency,
          notes: entry.notes,
          category: transaction.category && { id: transaction.category.id, name: transaction.category.name_with_parent }
        },
        message: "Transaction '#{entry.name}' created."
      }
    end

    def error_response?(value)
      value.is_a?(Hash) && value[:success] == false
    end

    def error(key, message)
      { success: false, error: key, message: message }
    end
end
