# frozen_string_literal: true

class AddRecurrenceCountToPlannedExpenses < ActiveRecord::Migration[7.2]
  def change
    add_column :planned_expenses, :recurrence_count_per_month, :integer, default: 1, null: false
  end
end
