class Assistant::Function::AnalyzeBudget < Assistant::Function
  include ActiveSupport::NumberHelper

  class << self
    def name
      "analyze_budget"
    end

    def description
      <<~INSTRUCTIONS
        Analyzes a monthly budget and returns data-backed, non-investment recommendations.
        Use this after get_budget when the user asks how to improve their budget or what
        needs attention. It identifies an unconfigured budget, unallocated money,
        overspending, unbudgeted spending, income shortfalls, and categories approaching
        their limit. It never changes financial data.

        `month` is optional and accepts YYYY-MM or MMM-YYYY. It defaults to the current month.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      properties: {
        month: {
          type: "string",
          description: "Target month in YYYY-MM or MMM-YYYY format. Defaults to the current month."
        }
      }
    )
  end

  def call(params = {})
    budget = find_budget(params["month"])
    return error("invalid_month", "The requested month is outside the supported budget range.") unless budget

    {
      success: true,
      month: budget.to_param,
      period: { start_date: budget.start_date, end_date: budget.end_date },
      currency: family.currency,
      initialized: budget.initialized?,
      recommendations: recommendations_for(budget)
    }
  rescue Assistant::Error => e
    error("invalid_month", e.message)
  end

  private
    def find_budget(raw_month)
      start_date = resolve_month_start(raw_month)
      return nil unless Budget.budget_date_valid?(start_date, family: family)

      Budget.find_or_bootstrap(family, start_date: start_date, user: user)
    end

    def recommendations_for(budget)
      return [ recommendation(
        type: "set_budget",
        priority: "high",
        message: "Set a monthly spending limit and expected income before allocating categories.",
        amounts: {
          estimated_monthly_spending: money(budget.estimated_spending),
          estimated_monthly_income: money(budget.estimated_income)
        }
      ) ] unless budget.initialized?

      recommendations = []
      add_income_shortfall(recommendations, budget)
      add_allocation_recommendation(recommendations, budget)
      add_category_recommendations(recommendations, budget)
      add_daily_pacing_recommendations(recommendations, budget)

      recommendations.presence || [ recommendation(
        type: "on_track",
        priority: "low",
        message: "This budget has no current allocation or spending issues.",
        amounts: { available_to_spend: money(budget.available_to_spend) }
      ) ]
    end

    def add_income_shortfall(recommendations, budget)
      return unless budget.expected_income.to_d.positive? && budget.remaining_expected_income.positive?

      recommendations << recommendation(
        type: "income_pending",
        priority: "medium",
        message: "Expected income has not yet been received in full; avoid relying on it until it arrives.",
        amounts: {
          expected_income: money(budget.expected_income),
          actual_income: money(budget.actual_income),
          remaining_expected_income: money(budget.remaining_expected_income)
        }
      )
    end

    def add_allocation_recommendation(recommendations, budget)
      return unless budget.available_to_allocate.positive?

      recommendations << recommendation(
        type: "allocate_remaining",
        priority: "medium",
        message: "Allocate the remaining budget to known upcoming expenses or leave it as an intentional buffer.",
        amounts: { available_to_allocate: money(budget.available_to_allocate) }
      )
    end

    def add_category_recommendations(recommendations, budget)
      budget.budget_categories.reject(&:subcategory?).each do |category|
        if category.over_budget_with_budget?
          recommendations << category_recommendation("over_budget", "high", category, "Spending exceeds this category's limit.")
        elsif category.unbudgeted_with_spending?
          recommendations << category_recommendation("unbudgeted_spending", "high", category, "This category has spending but no allocated budget.")
        elsif category.near_limit?
          recommendations << category_recommendation("near_limit", "medium", category, "Spending and planned expenses are close to this category's limit.")
        end
      end
    end

    def add_daily_pacing_recommendations(recommendations, budget)
      return unless budget.current?

      budget.budget_categories.reject(&:subcategory?).each do |category|
        suggestion = category.suggested_daily_spending
        next unless suggestion

        recommendations << recommendation(
          type: "daily_pace",
          priority: "low",
          category: { id: category.category_id, name: category.name },
          message: "To stay within this category's remaining amount, keep daily spending at or below the suggested pace.",
          amounts: {
            available_to_spend: money(category.available_to_spend),
            suggested_daily_spending: money(suggestion[:amount]),
            days_remaining: suggestion[:days_remaining]
          }
        )
      end
    end

    def category_recommendation(type, priority, category, message)
      recommendation(
        type: type,
        priority: priority,
        category: { id: category.category_id, name: category.name },
        message: message,
        amounts: {
          budgeted: money(category.display_budgeted_spending),
          actual: money(category.actual_spending),
          planned: money(category.planned_spending),
          available_to_spend: money(category.available_to_spend)
        }
      )
    end

    def recommendation(type:, priority:, message:, amounts:, category: nil)
      { type: type, priority: priority, message: message, category: category, amounts: amounts.compact }.compact
    end

    def money(amount)
      { amount: amount.to_d.to_s("F"), formatted: Money.new(amount || 0, family.currency).format }
    end

    def resolve_month_start(raw)
      base = parse_month(raw)
      return (base || Date.current).beginning_of_month unless family.uses_custom_month_start?

      base ? Date.new(base.year, base.month, family.month_start_day) : family.custom_month_start_for(Date.current)
    end

    def parse_month(raw)
      return nil if raw.blank?

      format = case raw
      when /\A\d{4}-\d{2}\z/ then "%Y-%m"
      when /\A[A-Za-z]{3}-\d{4}\z/ then "%b-%Y"
      end
      raise Assistant::Error, "Invalid month: #{raw}. Use YYYY-MM or MMM-YYYY." unless format

      Date.strptime(raw, format)
    rescue ArgumentError
      raise Assistant::Error, "Invalid month: #{raw}. Use YYYY-MM or MMM-YYYY."
    end

    def error(key, message)
      { success: false, error: key, message: message }
    end
end
