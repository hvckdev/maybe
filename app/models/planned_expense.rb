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
  validates :recurrence_type, presence: true, inclusion: { in: -> { recurrence_types.keys } }
  validates :recurrence_unit, presence: true, inclusion: { in: -> { recurrence_units.keys } }
  validates :recurrence_interval, numericality: { only_integer: true, greater_than: 0 }
  validates :recurrence_count_per_month, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 31 }
  validates :recurrence_day_of_month,
            numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 31 },
            allow_nil: true
  validates :recurrence_day_of_month, presence: true, if: :day_of_month_recurrence?

  before_validation :normalize_recurrence

  enum :status, { pending: "pending", confirmed: "confirmed", cancelled: "cancelled" }
  enum :recurrence_type, { interval: "interval", day_of_month: "day_of_month", times_per_month: "times_per_month" }, suffix: :recurrence
  enum :recurrence_unit, { days: "days", weeks: "weeks", months: "months" }, suffix: :recurrence_unit

  monetize :amount

  scope :recurring, -> { where(recurring: true) }

  def confirm!(date: Date.current, amount: nil)
    confirmation_date = date.to_date
    entry = nil

    transaction do
      entry = account.entries.create!(
        date: confirmation_date,
        name: name,
        amount: amount || self.amount,
        currency: currency,
        entryable: Transaction.new(category: category)
      )
      entry.mark_user_modified!
      update!(status: :confirmed, due_date: confirmation_date)
      schedule_next_monthly_occurrence_from!(confirmation_date) if monthly_interval_recurrence?
    end

    entry
  end

  def cancel!
    update!(status: :cancelled)
  end

  def reopen!
    update!(status: :pending)
  end

  def copy_to!(target_budget, due_date: next_due_date_for(target_budget))
    target_budget.planned_expenses.create!(
      category: category,
      account: account,
      name: name,
      amount: amount,
      currency: currency,
      status: :pending,
      recurring: recurring,
      due_date: due_date,
      recurrence_type: recurrence_type,
      recurrence_interval: recurrence_interval,
      recurrence_unit: recurrence_unit,
      recurrence_day_of_month: recurrence_day_of_month,
      recurrence_count_per_month: recurrence_count_per_month,
      recurrence_series_id: recurrence_series_id,
      notes: notes
    )
  end

  def recurrence_dates_for(target_budget)
    return [] unless recurring?

    if day_of_month_recurrence?
      day_of_month_dates_for(target_budget)
    elsif times_per_month_recurrence?
      times_per_month_dates_for(target_budget)
    else
      interval_dates_for(target_budget)
    end
  end

  def next_due_date_for(target_budget)
    recurrence_dates_for(target_budget).first || target_budget.start_date
  end

  def self.group_for_display(planned_expenses)
    planned_expenses
      .sort_by { |planned_expense| [ planned_expense.due_date || planned_expense.budget.start_date, planned_expense.created_at ] }
      .group_by(&:display_group_key)
      .values
      .map do |group|
        {
          planned_expense: group.first,
          occurrence_count: group.count,
          total_amount: group.sum(&:amount)
        }
      end
  end

  def recurrence_description
    return nil unless recurring?

    if day_of_month_recurrence?
      I18n.t("planned_expenses.recurrence_descriptions.day_of_month", day: recurrence_day_of_month)
    elsif times_per_month_recurrence?
      I18n.t("planned_expenses.recurrence_descriptions.times_per_month", count: recurrence_count_per_month)
    else
      I18n.t("planned_expenses.recurrence_descriptions.interval.#{recurrence_unit}", count: recurrence_interval)
    end
  end

  def display_group_key
    if multiple_occurrence_recurrence?
      [ :multiple_occurrence, recurrence_series_id || id ]
    else
      [ :single, id ]
    end
  end

  def materialize_multiple_occurrences_in_budget!
    return unless multiple_occurrence_recurrence?

    recurrence_dates_for(budget).each do |occurrence_date|
      next if budget.planned_expenses.exists?(recurrence_series_id: recurrence_series_id, due_date: occurrence_date)

      copy_to!(budget, due_date: occurrence_date)
    end
  end

  def propagate_day_of_month_to_existing_future_budgets!
    return unless recurring? && day_of_month_recurrence?

    budget.family.budgets
      .where("start_date > ?", budget.start_date)
      .order(:start_date)
      .find_each do |future_budget|
        recurrence_dates_for(future_budget).each do |future_due_date|
          upsert_future_occurrence!(future_budget, future_due_date)
        end
      end
  end

  def propagate_multiple_occurrences_to_existing_future_budgets!
    return unless multiple_occurrence_recurrence?

    budget.family.budgets
      .where("start_date > ?", budget.start_date)
      .order(:start_date)
      .find_each do |future_budget|
        recurrence_dates_for(future_budget).each do |future_due_date|
          upsert_future_occurrence!(future_budget, future_due_date)
        end
      end
  end

  private
    def normalize_recurrence
      self.due_date ||= budget&.start_date
      self.recurrence_type ||= "interval"
      self.recurrence_interval ||= 1
      self.recurrence_unit ||= "months"
      self.recurrence_count_per_month ||= 1

      if recurring?
        self.recurrence_series_id ||= SecureRandom.uuid
        self.recurrence_day_of_month ||= due_date&.day if day_of_month_recurrence?
      else
        self.recurrence_series_id = nil
        self.recurrence_day_of_month = nil unless day_of_month_recurrence?
      end
    end

    def schedule_next_monthly_occurrence_from!(confirmation_date)
      next_due_date = confirmation_date + recurrence_interval.months
      next_budget = budget.family.budgets.find_by("start_date <= ? AND end_date >= ?", next_due_date, next_due_date)
      return unless next_budget

      upsert_future_occurrence!(next_budget, next_due_date, replace_existing_series: true)
    end

    def upsert_future_occurrence!(target_budget, future_due_date, replace_existing_series: false)
      occurrence = if replace_existing_series
        target_budget.planned_expenses.pending.find_by(recurrence_series_id: recurrence_series_id)
      end

      occurrence ||= target_budget.planned_expenses.find_or_initialize_by(
        recurrence_series_id: recurrence_series_id,
        due_date: future_due_date
      )

      occurrence.assign_attributes(
        category: category,
        account: account,
        name: name,
        amount: amount,
        currency: currency,
        status: :pending,
        recurring: true,
        due_date: future_due_date,
        recurrence_type: recurrence_type,
        recurrence_interval: recurrence_interval,
        recurrence_unit: recurrence_unit,
        recurrence_day_of_month: recurrence_day_of_month,
        recurrence_count_per_month: recurrence_count_per_month,
        notes: notes
      )
      occurrence.save!
    end

    def monthly_interval_recurrence?
      recurring? && interval_recurrence? && months_recurrence_unit?
    end

    def short_interval_recurrence?
      recurring? && interval_recurrence? && (days_recurrence_unit? || weeks_recurrence_unit?)
    end

    def multiple_occurrence_recurrence?
      recurring? && (short_interval_recurrence? || times_per_month_recurrence?)
    end

    def interval_dates_for(target_budget)
      anchor_date = latest_confirmed_series_due_date_before(target_budget) || due_date || budget.start_date
      date = anchor_date

      date = advance_interval(date) while date < target_budget.start_date

      dates = []
      while date <= target_budget.end_date
        dates << date
        date = advance_interval(date)
      end
      dates
    end

    def latest_confirmed_series_due_date_before(target_budget)
      return unless monthly_interval_recurrence? && recurrence_series_id

      budget.family.planned_expenses.confirmed
        .joins(:budget)
        .where(recurrence_series_id: recurrence_series_id)
        .where("planned_expenses.due_date < ?", target_budget.start_date)
        .order(due_date: :desc)
        .pick(:due_date)
    end

    def day_of_month_dates_for(target_budget)
      date = target_budget.start_date.beginning_of_month
      dates = []

      while date <= target_budget.end_date
        occurrence = date.change(day: [ recurrence_day_of_month, date.end_of_month.day ].min)
        dates << occurrence if occurrence.between?(target_budget.start_date, target_budget.end_date)
        date = date.next_month.beginning_of_month
      end

      dates.uniq
    end

    def times_per_month_dates_for(target_budget)
      count = [ recurrence_count_per_month, 1 ].max
      return [ target_budget.start_date ] if count == 1

      period_length = (target_budget.end_date - target_budget.start_date).to_i
      step = period_length.to_f / (count - 1)

      count.times.map do |index|
        target_budget.start_date + (step * index).round.days
      end.uniq
    end

    def advance_interval(date)
      case recurrence_unit
      when "days" then date + recurrence_interval.days
      when "weeks" then date + recurrence_interval.weeks
      when "months" then date + recurrence_interval.months
      end
    end

    def monetizable_currency
      currency
    end
end
