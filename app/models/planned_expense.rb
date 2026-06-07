# frozen_string_literal: true

class PlannedExpense < ApplicationRecord
  include Monetizable

  belongs_to :budget
  belongs_to :category
  belongs_to :account

  validates :name, presence: true
  validates :amount, presence: true, numericality: { greater_than: 0 }
  validates :currency, presence: true
  validates :status, presence: true, inclusion: { in: -> { statuses.keys } }

  enum :status, { pending: "pending", confirmed: "confirmed", cancelled: "cancelled" }

  monetize :amount

  scope :recurring, -> { where(recurring: true) }

  def confirm!
    transaction do
      entry = account.entries.create!(
        date: Date.current,
        name: name,
        amount: -amount,
        currency: currency,
        entryable: Transaction.new(category: category)
      )
      entry.mark_user_modified!
      update!(status: :confirmed)
    end
  end

  def cancel!
    update!(status: :cancelled)
  end

  def reopen!
    update!(status: :pending)
  end

  def copy_to!(target_budget)
    target_budget.planned_expenses.create!(
      category: category,
      account: account,
      name: name,
      amount: amount,
      currency: currency,
      status: :pending,
      recurring: recurring,
      notes: notes
    )
  end

  private
    def monetizable_currency
      currency
    end
end
