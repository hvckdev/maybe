# frozen_string_literal: true

class AddAccountToPlannedExpenses < ActiveRecord::Migration[7.2]
  def change
    add_reference :planned_expenses, :account, foreign_key: true, type: :uuid
    remove_column :planned_expenses, :due_date, :date
  end
end
