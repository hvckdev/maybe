# frozen_string_literal: true

class AddRecurrenceRulesToPlannedExpenses < ActiveRecord::Migration[7.2]
  def change
    add_column :planned_expenses, :due_date, :date
    add_column :planned_expenses, :recurrence_type, :string, default: "interval", null: false
    add_column :planned_expenses, :recurrence_interval, :integer, default: 1, null: false
    add_column :planned_expenses, :recurrence_unit, :string, default: "months", null: false
    add_column :planned_expenses, :recurrence_day_of_month, :integer
    add_column :planned_expenses, :recurrence_series_id, :uuid

    add_index :planned_expenses, :recurrence_series_id
  end
end
