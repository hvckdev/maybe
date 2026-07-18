require "test_helper"

class Insight::Generators::BudgetInsightGeneratorTest < ActiveSupport::TestCase
  test "generates an insight when category overage uses unallocated budget" do
    family = families(:dylan_family)
    budget = Budget.new(
      family: family,
      start_date: Date.current.beginning_of_month,
      end_date: Date.current.end_of_month,
      budgeted_spending: 300,
      currency: family.currency
    )
    category = family.categories.create!(name: "Generator overage", color: "#111111")
    budget_category = BudgetCategory.new(budget: budget, category: category, budgeted_spending: 100, currency: family.currency)

    budget.stubs(:unplanned_spending_covered_by_unallocated).returns(50)
    budget.stubs(:unallocated_after_unplanned_spending).returns(25)
    budget.stubs(:percent_of_budget_spent).returns(50)
    budget.stubs(:budget_categories).returns([ budget_category ])
    budget_category.stubs(:over_budget_with_budget?).returns(false)
    budget_category.stubs(:budgeted?).returns(true)
    budget_category.stubs(:near_limit?).returns(false)

    generator = Insight::Generators::BudgetInsightGenerator.new(family)
    generator.stubs(:current_budget).returns(budget)

    insight = generator.generate.find { |generated| generated.insight_type == "budget_unplanned_spending" }

    assert_not_nil insight
    assert_equal "budget_unplanned_spending:#{Date.current.strftime("%Y-%m")}", insight.dedup_key
    assert_equal "$50.00", insight.facts[:covered_amount]
    assert_equal "$25.00", insight.facts[:unallocated_left]
    assert_equal 50.0, insight.metadata[:covered_amount]
  end
end
