# frozen_string_literal: true

class PlannedExpensesController < ApplicationController
  before_action :set_budget
  before_action :set_planned_expense, only: %i[update destroy confirm cancel]

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
      respond_to do |format|
        format.turbo_stream
        format.html { redirect_to budget_path(@budget) }
      end
    else
      render :new, status: :unprocessable_entity
    end
  end

  def update
    if @planned_expense.update(planned_expense_params)
      respond_to do |format|
        format.turbo_stream
        format.html { redirect_to budget_path(@budget) }
      end
    else
      render :new, status: :unprocessable_entity
    end
  end

  def destroy
    @planned_expense.destroy!

    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to budget_path(@budget) }
    end
  end

  def confirm
    @planned_expense.confirm!

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

  private
    def planned_expense_params
      params.require(:planned_expense).permit(:name, :amount, :category_id, :account_id, :recurring, :notes)
    end

    def set_budget
      start_date = Budget.param_to_date(params[:budget_month_year], family: Current.family)
      @budget = Current.family.budgets.find_by(start_date: start_date)
    end

    def set_planned_expense
      @planned_expense = @budget.planned_expenses.find(params[:id])
    end
end
