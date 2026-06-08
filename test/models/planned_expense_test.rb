# frozen_string_literal: true

require "test_helper"

class PlannedExpenseTest < ActiveSupport::TestCase
  setup do
    @budget = budgets(:one)
    @category = categories(:food_and_drink)
    @account = accounts(:depository)
  end

  test "creates a valid planned expense" do
    pe = PlannedExpense.new(
      budget: @budget,
      category: @category,
      account: @account,
      name: "Car insurance",
      amount: 500,
      currency: "USD"
    )
    assert pe.valid?
  end

  test "requires name" do
    pe = PlannedExpense.new(budget: @budget, category: @category, account: @account, amount: 100, currency: "USD")
    assert_not pe.valid?
    assert_includes pe.errors[:name], "can't be blank"
  end

  test "requires positive amount" do
    pe = PlannedExpense.new(budget: @budget, category: @category, account: @account, name: "Test", amount: 0, currency: "USD")
    assert_not pe.valid?

    pe.amount = -100
    assert_not pe.valid?
  end

  test "requires account" do
    pe = PlannedExpense.new(budget: @budget, category: @category, name: "Test", amount: 100, currency: "USD")
    assert_not pe.valid?
    assert_includes pe.errors[:account], "must exist"
  end

  test "defaults status to pending" do
    pe = PlannedExpense.create!(budget: @budget, category: @category, account: @account, name: "Test", amount: 100, currency: "USD")
    assert_equal "pending", pe.status
  end

  test "defaults recurring to false" do
    pe = PlannedExpense.create!(budget: @budget, category: @category, account: @account, name: "Test", amount: 100, currency: "USD")
    assert_not pe.recurring?
  end

  test "confirm! changes status to confirmed and creates transaction" do
    pe = PlannedExpense.create!(budget: @budget, category: @category, account: @account, name: "Test", amount: 100, currency: "USD")

    assert_difference "Entry.count", 1 do
      pe.confirm!
    end

    entry = @account.entries.order(:created_at).last
    assert_equal "Test", entry.name
    assert_equal(100, entry.amount)
    assert_equal Date.current, entry.date
    assert_equal "USD", entry.currency
    assert_equal "Transaction", entry.entryable_type
    assert_equal @category, entry.entryable.category
    assert entry.user_modified?
    assert_equal "confirmed", pe.reload.status
  end

  test "confirm! uses custom date and amount" do
    pe = PlannedExpense.create!(budget: @budget, category: @category, account: @account, name: "Test", amount: 100, currency: "USD")

    custom_date = 3.days.ago.to_date
    pe.confirm!(date: custom_date, amount: 150)

    entry = @account.entries.order(:created_at).last
    assert_equal custom_date, entry.date
    assert_equal(150, entry.amount)
  end

  test "cancel! changes status to cancelled" do
    pe = PlannedExpense.create!(budget: @budget, category: @category, account: @account, name: "Test", amount: 100, currency: "USD")
    pe.cancel!
    assert_equal "cancelled", pe.reload.status
  end

  test "reopen! changes status back to pending" do
    pe = PlannedExpense.create!(budget: @budget, category: @category, account: @account, name: "Test", amount: 100, currency: "USD")
    pe.confirm!
    pe.reopen!
    assert_equal "pending", pe.reload.status
  end

  test "copy_to! creates pending copy in target budget" do
    pe = PlannedExpense.create!(
      budget: @budget, category: @category, account: @account,
      name: "Car insurance", amount: 500, currency: "USD", recurring: true, notes: "Annual"
    )

    target_budget = Budget.create!(
      family: @budget.family,
      start_date: 1.month.from_now.beginning_of_month,
      end_date: 1.month.from_now.end_of_month,
      currency: "USD"
    )

    copy = pe.copy_to!(target_budget)
    assert_equal "pending", copy.status
    assert_equal "Car insurance", copy.name
    assert_equal 500, copy.amount
    assert_equal target_budget.id, copy.budget_id
    assert_equal @category.id, copy.category_id
    assert_equal @account.id, copy.account_id
    assert pe.recurring?
  end

  test "amount_money returns Money object" do
    pe = PlannedExpense.create!(budget: @budget, category: @category, account: @account, name: "Test", amount: 100, currency: "USD")
    assert_equal Money.new(100, "USD"), pe.amount_money
  end
end
