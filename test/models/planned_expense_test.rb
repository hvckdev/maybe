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
    assert_equal pe.recurrence_series_id, copy.recurrence_series_id
    assert pe.recurring?
  end

  test "recurrence_dates_for interval in weeks returns occurrences inside target budget" do
    source = Budget.create!(family: @budget.family, start_date: Date.new(2026, 1, 1), end_date: Date.new(2026, 1, 31), currency: "USD")
    target = Budget.create!(family: @budget.family, start_date: Date.new(2026, 2, 1), end_date: Date.new(2026, 2, 28), currency: "USD")
    pe = PlannedExpense.create!(
      budget: source, category: @category, account: @account,
      name: "Biweekly", amount: 100, currency: "USD", recurring: true,
      due_date: Date.new(2026, 1, 5), recurrence_interval: 2, recurrence_unit: "weeks"
    )

    assert_equal [ Date.new(2026, 2, 2), Date.new(2026, 2, 16) ], pe.recurrence_dates_for(target)
  end

  test "recurrence_dates_for interval in days supports custom gaps" do
    source = Budget.create!(family: @budget.family, start_date: Date.new(2026, 1, 1), end_date: Date.new(2026, 1, 31), currency: "USD")
    target = Budget.create!(family: @budget.family, start_date: Date.new(2026, 2, 1), end_date: Date.new(2026, 2, 10), currency: "USD")
    pe = PlannedExpense.create!(
      budget: source, category: @category, account: @account,
      name: "Every 3 days", amount: 25, currency: "USD", recurring: true,
      due_date: Date.new(2026, 1, 29), recurrence_interval: 3, recurrence_unit: "days"
    )

    assert_equal [ Date.new(2026, 2, 1), Date.new(2026, 2, 4), Date.new(2026, 2, 7), Date.new(2026, 2, 10) ], pe.recurrence_dates_for(target)
  end

  test "recurrence_dates_for day of month clamps to month end" do
    source = Budget.create!(family: @budget.family, start_date: Date.new(2026, 1, 1), end_date: Date.new(2026, 1, 31), currency: "USD")
    target = Budget.create!(family: @budget.family, start_date: Date.new(2026, 2, 1), end_date: Date.new(2026, 2, 28), currency: "USD")
    pe = PlannedExpense.create!(
      budget: source, category: @category, account: @account,
      name: "Month end", amount: 100, currency: "USD", recurring: true,
      recurrence_type: "day_of_month", recurrence_day_of_month: 31
    )

    assert_equal [ Date.new(2026, 2, 28) ], pe.recurrence_dates_for(target)
  end

  test "materialize_multiple_occurrences_in_budget creates weekly occurrences for current budget" do
    source = Budget.create!(family: @budget.family, start_date: Date.new(2026, 2, 1), end_date: Date.new(2026, 2, 28), currency: "USD")
    source.budget_categories.create!(category: @category, budgeted_spending: 0, currency: "USD")
    pe = PlannedExpense.create!(
      budget: source, category: @category, account: @account,
      name: "Weekly lessons", amount: 100, currency: "USD", recurring: true,
      due_date: Date.new(2026, 2, 2), recurrence_interval: 1, recurrence_unit: "weeks"
    )

    pe.materialize_multiple_occurrences_in_budget!

    assert_equal [ Date.new(2026, 2, 2), Date.new(2026, 2, 9), Date.new(2026, 2, 16), Date.new(2026, 2, 23) ], source.planned_expenses.order(:due_date).pluck(:due_date)
    assert_equal 400, source.reload.planned_spending
  end

  test "group_for_display collapses pending short interval occurrences" do
    source = Budget.create!(family: @budget.family, start_date: Date.new(2026, 2, 1), end_date: Date.new(2026, 2, 28), currency: "USD")
    source.budget_categories.create!(category: @category, budgeted_spending: 0, currency: "USD")
    pe = PlannedExpense.create!(
      budget: source, category: @category, account: @account,
      name: "Weekly lessons", amount: 100, currency: "USD", recurring: true,
      due_date: Date.new(2026, 2, 2), recurrence_interval: 1, recurrence_unit: "weeks"
    )
    pe.materialize_multiple_occurrences_in_budget!

    grouped = PlannedExpense.group_for_display(source.planned_expenses.pending)

    assert_equal 1, grouped.count
    assert_equal pe.recurrence_series_id, grouped.first[:planned_expense].recurrence_series_id
    assert_equal 4, grouped.first[:occurrence_count]
    assert_equal 400, grouped.first[:total_amount]
  end

  test "times per month recurrence creates configured number of grouped occurrences" do
    source = Budget.create!(family: @budget.family, start_date: Date.new(2026, 2, 1), end_date: Date.new(2026, 2, 28), currency: "USD")
    source.budget_categories.create!(category: @category, budgeted_spending: 0, currency: "USD")
    pe = PlannedExpense.create!(
      budget: source, category: @category, account: @account,
      name: "Therapy", amount: 75, currency: "USD", recurring: true,
      recurrence_type: "times_per_month", recurrence_count_per_month: 3
    )

    pe.materialize_multiple_occurrences_in_budget!

    assert_equal 3, source.planned_expenses.pending.count
    assert_equal 225, source.reload.planned_spending

    grouped = PlannedExpense.group_for_display(source.planned_expenses.pending)
    assert_equal 1, grouped.count
    assert_equal 3, grouped.first[:occurrence_count]
    assert_equal 225, grouped.first[:total_amount]
  end

  test "times per month recurrence type does not materialize occurrences when recurring is disabled" do
    source = Budget.create!(family: @budget.family, start_date: Date.new(2026, 2, 1), end_date: Date.new(2026, 2, 28), currency: "USD")
    source.budget_categories.create!(category: @category, budgeted_spending: 0, currency: "USD")
    pe = PlannedExpense.create!(
      budget: source, category: @category, account: @account,
      name: "One-off therapy", amount: 75, currency: "USD", recurring: false,
      recurrence_type: "times_per_month", recurrence_count_per_month: 3
    )

    pe.materialize_multiple_occurrences_in_budget!

    assert_equal 1, source.planned_expenses.count
    assert_equal 75, source.reload.planned_spending
  end

  test "confirmed short interval occurrence leaves remaining occurrences pending" do
    source = Budget.create!(family: @budget.family, start_date: Date.new(2026, 2, 1), end_date: Date.new(2026, 2, 28), currency: "USD")
    source.budget_categories.create!(category: @category, budgeted_spending: 0, currency: "USD")
    pe = PlannedExpense.create!(
      budget: source, category: @category, account: @account,
      name: "Every 10 days", amount: 50, currency: "USD", recurring: true,
      due_date: Date.new(2026, 2, 1), recurrence_interval: 10, recurrence_unit: "days"
    )
    pe.materialize_multiple_occurrences_in_budget!

    source.planned_expenses.order(:due_date).first.confirm!(date: Date.new(2026, 2, 1))

    assert_equal 2, source.planned_expenses.pending.count
    assert_equal [ Date.new(2026, 2, 11), Date.new(2026, 2, 21) ], source.planned_expenses.pending.order(:due_date).pluck(:due_date)
    assert_equal 100, source.reload.planned_spending
  end

  test "propagate_multiple_occurrences_to_existing_future_budgets creates all future month occurrences" do
    source = Budget.create!(family: @budget.family, start_date: Date.new(2026, 1, 1), end_date: Date.new(2026, 1, 31), currency: "USD")
    future = Budget.create!(family: @budget.family, start_date: Date.new(2026, 2, 1), end_date: Date.new(2026, 2, 28), currency: "USD")
    [ source, future ].each { |budget| budget.budget_categories.create!(category: @category, budgeted_spending: 0, currency: "USD") }
    pe = PlannedExpense.create!(
      budget: source, category: @category, account: @account,
      name: "Biweekly", amount: 100, currency: "USD", recurring: true,
      due_date: Date.new(2026, 1, 5), recurrence_interval: 2, recurrence_unit: "weeks"
    )

    pe.propagate_multiple_occurrences_to_existing_future_budgets!

    assert_equal [ Date.new(2026, 2, 2), Date.new(2026, 2, 16) ], future.planned_expenses.order(:due_date).pluck(:due_date)
    assert_equal 200, future.reload.planned_spending
  end

  test "propagate_day_of_month_to_existing_future_budgets creates occurrences in future budgets" do
    family = @budget.family
    source_start = Date.current.beginning_of_month + 1.month
    first_future_start = Date.current.beginning_of_month + 2.months
    second_future_start = Date.current.beginning_of_month + 3.months
    source = Budget.create!(family: family, start_date: source_start, end_date: source_start.end_of_month, currency: "USD")
    first_future = Budget.create!(family: family, start_date: first_future_start, end_date: first_future_start.end_of_month, currency: "USD")
    second_future = Budget.create!(family: family, start_date: second_future_start, end_date: second_future_start.end_of_month, currency: "USD")
    [ source, first_future, second_future ].each do |budget|
      budget.budget_categories.create!(category: @category, budgeted_spending: 0, currency: "USD")
    end
    pe = PlannedExpense.create!(
      budget: source, category: @category, account: @account,
      name: "Rent", amount: 1_000, currency: "USD", recurring: true,
      recurrence_type: "day_of_month", recurrence_day_of_month: 15
    )

    pe.propagate_day_of_month_to_existing_future_budgets!

    assert_equal [ first_future_start + 14.days ], first_future.planned_expenses.pluck(:due_date)
    assert_equal [ second_future_start + 14.days ], second_future.planned_expenses.pluck(:due_date)
  end

  test "confirm! schedules next monthly occurrence from confirmation date when next budget exists" do
    source_start = Date.current.beginning_of_month + 1.month
    target_start = Date.current.beginning_of_month + 2.months
    source = Budget.create!(family: @budget.family, start_date: source_start, end_date: source_start.end_of_month, currency: "USD")
    target = Budget.create!(family: @budget.family, start_date: target_start, end_date: target_start.end_of_month, currency: "USD")
    [ source, target ].each { |budget| budget.budget_categories.create!(category: @category, budgeted_spending: 0, currency: "USD") }
    pe = PlannedExpense.create!(
      budget: source, category: @category, account: @account,
      name: "Monthly", amount: 100, currency: "USD", recurring: true,
      due_date: source_start + 4.days, recurrence_interval: 1, recurrence_unit: "months"
    )
    pe.copy_to!(target, due_date: target_start + 4.days)

    pe.confirm!(date: source_start + 9.days)

    assert_equal [ source_start + 1.month + 9.days ], target.planned_expenses.reload.pluck(:due_date)
  end

  test "new budget uses previous monthly confirmation date when next budget did not exist" do
    family = @budget.family
    source_start = Date.current.beginning_of_month + 1.month
    target_start = Date.current.beginning_of_month + 2.months
    source = Budget.create!(family: family, start_date: source_start, end_date: source_start.end_of_month, currency: "USD")
    source.budget_categories.create!(category: @category, budgeted_spending: 0, currency: "USD")
    pe = PlannedExpense.create!(
      budget: source, category: @category, account: @account,
      name: "Monthly", amount: 100, currency: "USD", recurring: true,
      due_date: source_start + 2.days, recurrence_interval: 1, recurrence_unit: "months"
    )
    pe.confirm!(date: source_start + 11.days)

    target = Budget.find_or_bootstrap(family, start_date: target_start)

    assert_equal [ source_start + 1.month + 11.days ], target.planned_expenses.pluck(:due_date)
  end

  test "amount_money returns Money object" do
    pe = PlannedExpense.create!(budget: @budget, category: @category, account: @account, name: "Test", amount: 100, currency: "USD")
    assert_equal Money.new(100, "USD"), pe.amount_money
  end
end
