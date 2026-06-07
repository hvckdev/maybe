# frozen_string_literal: true

class CreatePlannedExpenses < ActiveRecord::Migration[7.2]
  def change
    create_table :planned_expenses, id: :uuid do |t|
      t.references :budget, null: false, foreign_key: true, type: :uuid
      t.references :category, null: false, foreign_key: true, type: :uuid
      t.string :name, null: false
      t.decimal :amount, precision: 19, scale: 4, null: false
      t.string :currency, null: false
      t.string :status, default: "pending", null: false
      t.boolean :recurring, default: false, null: false
      t.date :due_date
      t.text :notes

      t.timestamps
    end

    add_index :planned_expenses, [ :budget_id, :status ]
    add_index :planned_expenses, [ :budget_id, :category_id ]
  end
end
