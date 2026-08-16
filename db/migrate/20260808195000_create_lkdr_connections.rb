class CreateLkdrConnections < ActiveRecord::Migration[7.2]
  def change
    create_table :lkdr_connections, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid, index: { unique: true }
      t.string :phone
      t.text :refresh_token
      t.text :challenge_token
      t.datetime :challenge_expires_at
      t.string :status, null: false, default: "pending"
      t.datetime :last_synced_at
      t.text :last_error
      t.timestamps
    end

  end
end
