# frozen_string_literal: true

class PlannedExpensesController < ApplicationController
  before_action :set_budget
  before_action :set_planned_expense, only: %i[edit update destroy confirm do_confirm cancel reopen delete_confirmation]

  def new
    @planned_expense = @budget.planned_expenses.build(
      currency: @budget.currency || Current.family.currency,
      category_id: params[:category_id]
    )
  end

  def create
    @planned_expense = @budget.planned_expenses.build(planned_expense_params)
    @planned_expense.currency ||= @budget.currency || Current.family.currency

    if @planned_expense.save
      @planned_expense.materialize_multiple_occurrences_in_budget!
      @planned_expense.propagate_multiple_occurrences_to_existing_future_budgets!
      @planned_expense.propagate_day_of_month_to_existing_future_budgets!

      respond_to do |format|
        format.turbo_stream
        format.html { redirect_to budget_path(@budget) }
      end
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @planned_expense.update(planned_expense_params)
      @planned_expense.materialize_multiple_occurrences_in_budget!
      @planned_expense.propagate_multiple_occurrences_to_existing_future_budgets!
      @planned_expense.propagate_day_of_month_to_existing_future_budgets!

      respond_to do |format|
        format.turbo_stream
        format.html { redirect_to budget_path(@budget) }
      end
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def delete_confirmation
    @occurrence_count = @planned_expense.pending_occurrences_in_budget.count
  end

  def destroy
    if params[:delete_scope] == "forever" && @planned_expense.recurring?
      @planned_expense.stop_recurrence!
    elsif params[:delete_scope] == "current_budget" && @planned_expense.recurring?
      @planned_expense.delete_pending_occurrences_in_budget!(occurrence_count_param)
    else
      @planned_expense.destroy!
    end

    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to budget_path(@budget) }
    end
  rescue ArgumentError
    @occurrence_count = @planned_expense.pending_occurrences_in_budget.count
    render :delete_confirmation, status: :unprocessable_entity
  end

  def confirm
    # GET — show confirm form in drawer
  end

  def do_confirm
    # POST — process confirmation
    date = params[:planned_expense][:date]
    amount = params[:planned_expense][:amount]
    @confirmed_entry = @planned_expense.confirm!(date: date, amount: amount)

    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to budget_path(@budget) }
    end
  end

  def cancel
    @planned_expense.cancel!

    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to budget_path(@budget) }
    end
  end

  def reopen
    @planned_expense.reopen!

    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to budget_path(@budget) }
    end
  end

  private
    def planned_expense_params
      params.require(:planned_expense).permit(
        :name, :amount, :category_id, :account_id, :due_date, :recurring,
        :recurrence_type, :recurrence_interval, :recurrence_unit,
        :recurrence_day_of_month, :recurrence_count_per_month,
        :notes
      )
    end

    def occurrence_count_param
      Integer(params[:occurrence_count], exception: false) || 0
    end

    def set_budget
      start_date = Budget.param_to_date(params[:budget_month_year], family: Current.family)
      @budget = Current.family.budgets.find_by(start_date: start_date)
    end

    def set_planned_expense
      @planned_expense = @budget.planned_expenses.find(params[:id])
    end
end
