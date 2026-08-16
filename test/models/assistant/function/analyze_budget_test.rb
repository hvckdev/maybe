require "test_helper"

class Assistant::Function::AnalyzeBudgetTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @function = Assistant::Function::AnalyzeBudget.new(@user)
  end

  test "recommends setting a budget when the month is uninitialized" do
    result = @function.call({})

    assert result[:success]
    refute result[:initialized]
    recommendation = result[:recommendations].first
    assert_equal "set_budget", recommendation[:type]
    assert_equal "high", recommendation[:priority]
    assert recommendation[:amounts][:estimated_monthly_spending]
  end

  test "identifies an over-budget category" do
    budget = Budget.find_or_bootstrap(@family, start_date: Date.current, user: @user)
    food = budget.budget_categories.find_by!(category: categories(:food_and_drink))
    budget.update!(budgeted_spending: 100)
    food.update!(budgeted_spending: 100)
    BudgetCategory.any_instance.stubs(:actual_spending).returns(125)

    result = @function.call({})

    over_budget = result[:recommendations].find { |item| item[:type] == "over_budget" }
    assert over_budget
    assert_equal food.category_id, over_budget[:category][:id]
    assert_equal "125.0", over_budget[:amounts][:actual][:amount]
  end

  test "rejects invalid months" do
    result = @function.call("month" => "tomorrow")

    assert_equal false, result[:success]
    assert_equal "invalid_month", result[:error]
  end
end
