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
    preview = @function.call(transaction_params)

    assert_difference "@account.entries.count", 1 do
      result = @function.call(transaction_params.merge(
        "confirmation_token" => preview[:confirmation_token],
        "confirmed" => true
      ))

      assert result[:success], result.inspect
      assert_equal "Lunch", result.dig(:transaction, :name)
      assert_equal 24.5, result.dig(:transaction, :amount)
      assert_equal @category.id, result.dig(:transaction, :category, :id)
    end

    entry = @account.entries.order(:created_at).last
    assert entry.user_modified?
    assert entry.locked?(:name)
  end

  test "creates income with a negative signed amount" do
    preview = @function.call(transaction_params("transaction_type" => "income", "amount" => 1_000))

    result = @function.call(transaction_params("transaction_type" => "income", "amount" => 1_000).merge(
      "confirmation_token" => preview[:confirmation_token],
      "confirmed" => true
    ))

    assert result[:success], result.inspect
    assert_equal(-1_000.0, result.dig(:transaction, :amount))
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
      @function.call(confirmed_params)
      retry_result = @function.call(confirmed_params)
      assert retry_result[:success], retry_result.inspect
    end
  end

  test "rejects an account the user cannot write to" do
    shared_account = accounts(:credit_card)
    function = Assistant::Function::CreateTransaction.new(users(:family_member))

    result = function.call(transaction_params("account_id" => shared_account.id))

    assert_equal false, result[:success]
    assert_equal "account_not_found", result[:error]
  end

  test "rejects a category outside the family" do
    foreign_category = families(:empty).categories.create!(name: "Foreign", color: "#e99537", lucide_icon: "tag")

    result = @function.call(transaction_params("category_id" => foreign_category.id))

    assert_equal false, result[:success]
    assert_equal "invalid_category", result[:error]
  end

  private
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
