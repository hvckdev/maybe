# frozen_string_literal: true

class MakeAccountRequiredOnPlannedExpenses < ActiveRecord::Migration[7.2]
  def up
    # Remove any planned expenses without an account (orphaned data)
    PlannedExpense.where(account_id: nil).destroy_all
    change_column_null :planned_expenses, :account_id, false
  end

  def down
    change_column_null :planned_expenses, :account_id, true
  end
end
