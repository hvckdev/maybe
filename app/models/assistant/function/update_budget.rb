class Assistant::Function::UpdateBudget < Assistant::Function
  include Assistant::Function::MonthResolvable

  class << self
    def name
      "update_budget"
    end

    def description
      <<~INSTRUCTIONS
        Updates the user's monthly budget after the user has explicitly approved the amounts:
        total budgeted spending, expected income, and/or per-category allocations.

        Call get_budget first to see current amounts and exact category names. Amounts are
        plain non-negative numbers in the family's currency. Only the fields and categories
        you pass are changed. Setting a subcategory's amount keeps its parent's total in sync
        automatically. The "Uncategorized" bucket cannot be set directly — it is the
        unallocated remainder of total budgeted spending.

        Parameters:
        - `month` (optional): "YYYY-MM" or "MMM-YYYY". Defaults to the current month.
        - `budgeted_spending` (optional): total planned spending for the month.
        - `expected_income` (optional): expected income for the month.
        - `categories` (optional): array of { category: <name or id>, amount: <number> }.
        - `category_allocations` (optional): array of { category_id: <id>, amount: <number> }.

        At least one of budgeted_spending, expected_income, categories, or
        category_allocations is required.
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
        },
        budgeted_spending: {
          type: "number",
          minimum: 0,
          description: "Total planned spending for the month, in the family currency."
        },
        expected_income: {
          type: "number",
          minimum: 0,
          description: "Expected income for the month, in the family currency."
        },
        categories: {
          type: "array",
          description: "Per-category budget allocations to set by exact name (case-insensitive) or category ID.",
          items: category_allocation_schema("category", "Category name or ID from get_budget.")
        },
        category_allocations: {
          type: "array",
          description: "Per-category budget allocations to set by category ID from get_budget.",
          items: category_allocation_schema("category_id", "Category ID from get_budget.")
        }
      }
    )
  end

  def call(params = {})
    category_changes = category_changes(params)
    unless params.key?("budgeted_spending") || params.key?("expected_income") || category_changes.any?
      return error("no_changes", "Provide at least one of budgeted_spending, expected_income, categories, or category_allocations.")
    end

    start_date = resolve_month_start(params["month"])
    unless Budget.budget_date_valid?(start_date, family: family)
      return error("invalid_month", "No budget exists (or can be created) for that month — it is outside the valid budget range.")
    end

    attributes = budget_attributes(params)
    budget = nil
    updated = []

    # Bootstrap and all writes share one transaction so a bad entry cannot leave
    # a newly created (or partially updated) budget behind.
    Budget.transaction do
      budget = Budget.find_or_bootstrap(family, start_date: start_date, user: user)
      changes = category_changes.map do |reference, amount, id_only|
        budget_category = find_budget_category!(budget, reference, id_only: id_only)
        [ budget_category, parse_amount!(amount, "amount for '#{budget_category.name}'") ]
      end

      budget.update!(attributes) if attributes.any?

      # Subcategory updates sync their parent's total, so explicit parent amounts
      # apply last and produce the same result regardless of request ordering.
      subcategories, parents = changes.partition { |budget_category, _amount| budget_category.subcategory? }
      (subcategories + parents).each do |budget_category, amount|
        budget_category.update_budgeted_spending!(amount)
        updated << { category: budget_category.name, budgeted_spending: format_money(budget_category.reload.budgeted_spending) }
      end
    end

    budget.reload
    {
      success: true,
      month: budget.to_param,
      totals: totals(budget),
      budget: serialize(budget),
      updated_categories: updated,
      message: "Budget for #{budget.start_date.strftime('%B %Y')} updated."
    }
  rescue Assistant::Error => e
    error("invalid_params", e.message)
  rescue ActiveRecord::RecordInvalid => e
    error("validation_failed", e.record.errors.full_messages.join("; "))
  end

  private
    def category_allocation_schema(reference_key, reference_description)
      {
        type: "object",
        properties: {
          reference_key.to_sym => { type: "string", description: reference_description },
          amount: { type: "number", minimum: 0, description: "New budgeted amount for this category." }
        },
        required: [ reference_key, "amount" ],
        additionalProperties: false
      }
    end

    def category_changes(params)
      named = Array(params["categories"]).map do |change|
        [ change.is_a?(Hash) ? change["category"] : nil, change.is_a?(Hash) ? change["amount"] : nil, false ]
      end
      identified = Array(params["category_allocations"]).map do |allocation|
        [ allocation.is_a?(Hash) ? allocation["category_id"] : nil, allocation.is_a?(Hash) ? allocation["amount"] : nil, true ]
      end

      named + identified
    end

    def budget_attributes(params)
      attributes = {}
      attributes[:budgeted_spending] = parse_amount!(params["budgeted_spending"], "budgeted_spending") if params.key?("budgeted_spending")
      attributes[:expected_income] = parse_amount!(params["expected_income"], "expected_income") if params.key?("expected_income")
      attributes
    end

    def parse_amount!(raw, label)
      value = Float(raw)
      raise Assistant::Error, "#{label} must be a non-negative number." if !value.finite? || value.negative?

      value
    rescue ArgumentError, TypeError
      raise Assistant::Error, "#{label} must be a non-negative number."
    end

    def find_budget_category!(budget, ref, id_only: false)
      ref = ref.to_s.strip
      raise Assistant::Error, "Each category allocation needs a category name or ID." if ref.blank?
      raise Assistant::Error, "category_id must be a valid category ID." if id_only && !valid_uuid?(ref)

      category = valid_uuid?(ref) ? family.categories.find_by(id: ref) : nil
      category ||= family.categories.where("LOWER(name) = ?", ref.downcase).first unless id_only

      if category.nil?
        if Category.all_uncategorized_names.any? { |name| name.casecmp?(ref) }
          raise Assistant::Error, "'#{ref}' is the unallocated remainder of budgeted_spending and cannot be set directly. Adjust budgeted_spending or category amounts instead."
        end
        raise Assistant::Error, "Category '#{ref}' not found. Use get_budget to list categories."
      end

      budget.budget_categories.find_by(category_id: category.id) ||
        raise(Assistant::Error, "No budget row exists for category '#{category.name}' in #{budget.to_param}.")
    end

    def totals(budget)
      {
        budgeted_spending: format_money(budget.budgeted_spending),
        expected_income: format_money(budget.expected_income),
        allocated_spending: format_money(budget.allocated_spending),
        available_to_allocate: format_money(budget.available_to_allocate)
      }
    end

    def serialize(budget)
      {
        month: budget.to_param,
        period: { start_date: budget.start_date, end_date: budget.end_date },
        budgeted_spending: money(budget.budgeted_spending),
        expected_income: money(budget.expected_income),
        allocated_spending: money(budget.allocated_spending),
        available_to_allocate: money(budget.available_to_allocate)
      }
    end

    def format_money(value)
      Money.new(value || 0, family.currency).format
    end

    def money(amount)
      { amount: amount.to_d.to_s("F"), formatted: format_money(amount) }
    end

    def error(key, message)
      { success: false, error: key, message: message }
    end
end
