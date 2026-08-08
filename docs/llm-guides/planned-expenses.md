# Planned expenses

Use this guide before changing expected/planned expenses. The feature is implemented by `PlannedExpense` records; there is no separate recurring-expense model.

## Domain model

`PlannedExpense` belongs to a `Budget`, `Category`, and `Account`.

- `status`: `pending`, `confirmed`, or `cancelled`.
- Only `pending` expenses affect `Budget#planned_spending` and therefore `Budget#available_to_spend`.
- `recurring` enables recurrence. A recurring record receives a `recurrence_series_id`, which identifies the series across budget periods.
- A series is represented by one or more `PlannedExpense` records, not by a single template record. Do not assume the record currently being viewed is the only record in the series.

Relevant schema fields:

- `due_date`
- `recurrence_type`: `interval`, `day_of_month`, or `times_per_month`
- `recurrence_interval` and `recurrence_unit` (`days`, `weeks`, `months`)
- `recurrence_day_of_month`
- `recurrence_count_per_month`
- `recurrence_series_id`

## Creation and materialization

The web entry point is `PlannedExpensesController`.

After a successful create or update, the controller calls:

1. `materialize_multiple_occurrences_in_budget!` — creates the remaining in-period occurrences for day/week intervals and `times_per_month`.
2. `propagate_multiple_occurrences_to_existing_future_budgets!` — fills already-created future budgets for those same recurrence types.
3. `propagate_day_of_month_to_existing_future_budgets!` — fills already-created future budgets for day-of-month recurrences.

`Budget.find_or_bootstrap` creates a budget period when needed, synchronizes its categories, and then calls `populate_recurring_planned_expenses!` once for a newly created budget. That method:

- considers recurring expenses in earlier family budgets;
- groups them by `recurrence_series_id` (falling back to the record id for legacy data);
- uses the earliest occurrence as the source;
- creates only due dates inside the new budget period;
- skips a date that already exists for the same series.

`Budget#copy_from!` also copies recurring expenses from a selected prior budget into the target period. It uses one source per series.

**Implication:** destroying only the current occurrence does not stop a series. Older recurring records remain candidates for later `populate_recurring_planned_expenses!` or `copy_from!` calls.

## Recurrence date rules

`PlannedExpense#recurrence_dates_for(target_budget)` is the central date calculation.

- `interval` advances by its configured days, weeks, or months.
- `day_of_month` creates one date per calendar month in the budget period, clamping e.g. day 31 to February's last day.
- `times_per_month` distributes the configured number of dates from the period start through the period end.
- Day/week interval and `times_per_month` records are considered multiple-occurrence recurrences and are grouped in the UI by `recurrence_series_id`.
- A monthly interval is special: `confirm!` schedules the next occurrence based on the actual confirmation date. It updates/reuses a pending occurrence in the next existing budget where possible.

## Confirmation, cancellation, and deletion

- `confirm!` creates an account `Entry` with a `Transaction` in the planned expense category, marks the entry user-modified, and changes the planned expense to `confirmed`.
- `cancel!` only changes the status to `cancelled`; it does not end recurrence.
- `reopen!` changes the status back to `pending`.
- Non-recurring expenses are destroyed directly.

For recurring expenses, the delete drawer has two intentionally different operations:

1. `delete_pending_occurrences_in_budget!(count)` deletes the earliest `count` pending occurrences of the series in the current budget only. It creates a one-period gap and leaves future recurrence active.
2. `stop_recurrence!` removes every pending occurrence in the series across the family and sets `recurring: false` on resolved records. Keeping resolved records preserves history, while disabling recurrence prevents them from seeding new future budget occurrences.

Do not replace `stop_recurrence!` with deletion of just the visible record: that was the source of the bug where the expense reappeared next month.

## UI and routes

- Budget render: `app/views/budgets/_planned_expenses.html.erb`
- Operations render: the `planned` tab in `app/views/transactions/index.html.erb`, backed by `@planned_expenses` from `TransactionsController#index`.
- Operations use the current family budget period, including custom month boundaries.
- List item: `app/views/planned_expenses/_planned_expense.html.erb`
- Recurring delete drawer: `app/views/planned_expenses/delete_confirmation.html.erb`
- Route: `GET /budgets/:budget_month_year/planned_expenses/:id/delete_confirmation`, followed by the normal `DELETE` route with `delete_scope` set to `current_budget` or `forever`.

Keep strings in `config/locales/views/planned_expenses/{en,ru}.yml`, use the drawer/Turbo convention, and retain direct delete confirmation for non-recurring expenses.

## Tests

Primary model coverage: `test/models/planned_expense_test.rb`.

When changing recurrence logic, cover at least:

- dates in a target budget;
- creation of future-budget occurrences;
- confirmation behavior for monthly intervals;
- effect on `planned_spending` when relevant;
- both scoped deletion and permanent series termination.
