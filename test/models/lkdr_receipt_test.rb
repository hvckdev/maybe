require "test_helper"

class LkdrReceiptTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(
      name: "Cash",
      balance: 0,
      currency: "RUB",
      accountable: Depository.new
    )
    @receipt = @family.lkdr_receipts.create!(
      external_key: "928244|1|2026-08-08|42|9999999999999999",
      merchant_name: "Coffee Shop",
      merchant_inn: "7701234567",
      purchased_at: Date.new(2026, 8, 8),
      total_amount: 249.50
    )
  end

  test "imports a receipt as an expense with its fiscal key" do
    assert_difference [ "Entry.count", "Transaction.count" ], 1 do
      @receipt.import_into!(account: @account)
    end

    entry = @receipt.reload.entry
    assert_equal @account, entry.account
    assert_equal "Coffee Shop", entry.name
    assert_equal Date.new(2026, 8, 8), entry.date
    assert_equal 249.50.to_d, entry.amount
    assert_equal "RUB", entry.currency
    assert_equal "lkdr", entry.source
    assert_equal @receipt.external_key, entry.external_id
    assert_includes entry.notes, "7701234567"
  end

  test "does not duplicate a receipt on repeated import" do
    @receipt.import_into!(account: @account)

    assert_no_difference [ "Entry.count", "Transaction.count" ] do
      assert_equal @receipt.entry, @receipt.import_into!(account: @account)
    end
  end
end
