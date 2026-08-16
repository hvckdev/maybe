class CreateLkdrReceipts < ActiveRecord::Migration[7.2]
  def change
    create_table :lkdr_receipts, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.references :entry, foreign_key: true, type: :uuid
      t.string :external_key, null: false
      t.string :merchant_name, null: false
      t.string :merchant_inn
      t.date :purchased_at, null: false
      t.decimal :total_amount, precision: 19, scale: 4, null: false
      t.string :currency, null: false, default: "RUB"
      t.string :fiscal_drive_number
      t.string :fiscal_document_number
      t.string :fiscal_sign
      t.jsonb :raw_payload, null: false, default: {}
      t.timestamps
    end

    add_index :lkdr_receipts, [ :family_id, :external_key ], unique: true
    add_check_constraint :lkdr_receipts, "total_amount > 0", name: "lkdr_receipts_total_amount_positive"
  end
end
