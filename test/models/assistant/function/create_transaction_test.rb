require "test_helper"

class Assistant::Function::CreateTransactionTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @account = accounts(:depository)
    @category = categories(:food_and_drink)
    @function = Assistant::Function::CreateTransaction.new(@user)
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @original_cache
  end

  test "returns a preview without creating a transaction" do
    assert_no_difference "@account.entries.count" do
      result = @function.call(transaction_params)

      assert_equal false, result[:success]
      assert_equal true, result[:confirmation_required]
      assert result[:confirmation_token].present?
      assert_equal "expense", result.dig(:transaction, :transaction_type)
      assert_equal 24.5, result.dig(:transaction, :signed_amount)
      assert_equal @category.id, result.dig(:transaction, :category, :id)
    end
  end

  test "creates an expense only after a matching explicit confirmation" do
    assert_difference "@account.entries.count", 1 do
      result = confirm(transaction_params)

      assert result[:success], result.inspect
      assert_equal true, result[:created]
      assert_equal "Lunch", result.dig(:transaction, :name)
      assert_equal 24.5, result.dig(:transaction, :amount)
      assert_equal @category.id, result.dig(:transaction, :category, :id)
    end

    entry = @account.entries.order(:created_at).last
    assert entry.user_modified?
    assert entry.locked?(:name)
  end

  test "creates income with a negative signed amount" do
    result = confirm(transaction_params("transaction_type" => "income", "amount" => 1_000))

    assert result[:success], result.inspect
    assert_equal(-1_000.0, result.dig(:transaction, :amount))
    assert_equal "income", result.dig(:transaction, :transaction_type)
  end

  test "accepts the legacy type parameter" do
    result = confirm(transaction_params.except("transaction_type").merge("type" => "inflow"))

    assert result[:success], result.inspect
    assert_equal(-24.5, result.dig(:transaction, :amount))
  end

  test "creates a transaction with a zero amount" do
    result = confirm(transaction_params("amount" => 0))

    assert result[:success], result.inspect
    assert_equal 0.0, result.dig(:transaction, :amount)
  end

  test "creates a transaction with category, merchant, and tags" do
    merchant = merchants(:amazon)
    tag = tags(:one)

    result = confirm(transaction_params(
      "merchant_id" => merchant.id,
      "tag_ids" => [ tag.id ]
    ))

    assert result[:success], result.inspect
    transaction = Transaction.find(result.dig(:transaction, :id))
    assert_equal @category, transaction.category
    assert_equal merchant, transaction.merchant
    assert_equal [ tag.id ], transaction.tag_ids
  end

  test "does not create when confirmation is missing or false" do
    preview = @function.call(transaction_params)

    assert_no_difference "@account.entries.count" do
      missing = @function.call(transaction_params.merge("confirmation_token" => preview[:confirmation_token]))
      false_confirmation = @function.call(transaction_params.merge("confirmation_token" => preview[:confirmation_token], "confirmed" => false))

      assert_equal true, missing[:confirmation_required]
      assert_equal true, false_confirmation[:confirmation_required]
    end
  end

  test "rejects a confirmation token for changed transaction details" do
    preview = @function.call(transaction_params)

    assert_no_difference "@account.entries.count" do
      result = @function.call(transaction_params("amount" => 30).merge(
        "confirmation_token" => preview[:confirmation_token],
        "confirmed" => true
      ))

      assert_equal false, result[:success]
      assert_equal "invalid_confirmation", result[:error]
    end
  end

  test "does not duplicate a confirmed transaction on retry" do
    preview = @function.call(transaction_params)
    confirmed_params = transaction_params.merge("confirmation_token" => preview[:confirmation_token], "confirmed" => true)

    assert_difference "@account.entries.count", 1 do
      first = @function.call(confirmed_params)
      retry_result = @function.call(confirmed_params)

      assert first[:success], first.inspect
      assert_equal false, retry_result[:created]
      assert_equal first.dig(:transaction, :id), retry_result.dig(:transaction, :id)
    end
  end

  test "is idempotent across confirmations when external_id and source match" do
    params = transaction_params("external_id" => "xmoney-001", "source" => "xmoney")
    first = confirm(params)
    second = confirm(params)

    assert first[:success], first.inspect
    assert_equal true, first[:created]
    assert second[:success], second.inspect
    assert_equal false, second[:created]
    assert_equal first.dig(:transaction, :id), second.dig(:transaction, :id)
  end

  test "reports created with a warning when the post-create sync fails to enqueue" do
    Entry.any_instance.stubs(:sync_account_later).raises(StandardError, "job backend unavailable")

    result = confirm(transaction_params("name" => "Sync Failure Case"))

    assert result[:success], result.inspect
    assert_equal true, result[:created]
    assert_match(/could not be enqueued/, result[:warning])
    assert Entry.find_by(name: "Sync Failure Case", account: @account)
  end

  test "rejects an account the user cannot write to" do
    shared_account = accounts(:credit_card)
    function = Assistant::Function::CreateTransaction.new(users(:family_member))

    result = function.call(transaction_params("account_id" => shared_account.id))

    assert_equal false, result[:success]
    assert_equal "account_not_found", result[:error]
  end

  test "does not let a user from a different family create in an account" do
    function = Assistant::Function::CreateTransaction.new(users(:josh))

    result = function.call(transaction_params)

    assert_equal false, result[:success]
    assert_equal "account_not_found", result[:error]
    assert_nil Entry.find_by(name: "Lunch", account: @account, date: Date.current)
  end

  test "rejects a non-UUID account_id" do
    result = @function.call(transaction_params("account_id" => "not-a-uuid"))

    assert_equal false, result[:success]
    assert_equal "account_not_found", result[:error]
  end

  test "rejects an invalid date" do
    result = @function.call(transaction_params("date" => "not-a-date"))

    assert_equal false, result[:success]
    assert_equal "invalid_date", result[:error]
  end

  test "defaults the date to today" do
    result = confirm(transaction_params.except("date"))

    assert result[:success], result.inspect
    assert_equal Date.current, result.dig(:transaction, :date)
  end

  test "rejects an invalid amount" do
    result = @function.call(transaction_params("amount" => "abc"))

    assert_equal false, result[:success]
    assert_equal "invalid_amount", result[:error]
  end

  test "rejects a negative magnitude" do
    result = @function.call(transaction_params("amount" => -10))

    assert_equal false, result[:success]
    assert_equal "invalid_amount", result[:error]
  end

  test "rejects an invalid transaction type" do
    result = @function.call(transaction_params("transaction_type" => "transfer"))

    assert_equal false, result[:success]
    assert_equal "invalid_transaction_type", result[:error]
  end

  test "rejects an empty name" do
    result = @function.call(transaction_params("name" => "   "))

    assert_equal false, result[:success]
    assert_equal "invalid_name", result[:error]
  end

  test "rejects an invalid currency" do
    result = @function.call(transaction_params("currency" => "NOT_A_CURRENCY"))

    assert_equal false, result[:success]
    assert_equal "invalid_currency", result[:error]
  end

  test "rejects a category outside the family" do
    foreign_category = families(:empty).categories.create!(name: "Foreign", color: "#e99537", lucide_icon: "tag")

    result = @function.call(transaction_params("category_id" => foreign_category.id))

    assert_equal false, result[:success]
    assert_equal "invalid_category", result[:error]
  end

  private
    def confirm(params)
      preview = @function.call(params)
      assert_equal true, preview[:confirmation_required], preview.inspect

      @function.call(params.merge(
        "confirmation_token" => preview[:confirmation_token],
        "confirmed" => true
      ))
    end

    def transaction_params(overrides = {})
      {
        "account_id" => @account.id,
        "amount" => 24.5,
        "transaction_type" => "expense",
        "name" => "Lunch",
        "date" => Date.current.iso8601,
        "category_id" => @category.id,
        "notes" => "With team"
      }.merge(overrides)
    end
end
