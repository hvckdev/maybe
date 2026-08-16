class LkdrReceiptsController < ApplicationController
  before_action :set_receipt

  def import
    account = Current.user.accessible_accounts.find(params.require(:account_id))
    return unless require_account_permission!(account)

    @receipt.import_into!(account: account)
    account.sync_later

    redirect_to transactions_path(tab: "receipts"), notice: t("lkdr_receipts.import.success")
  rescue ActiveRecord::RecordInvalid, ArgumentError => e
    redirect_to transactions_path(tab: "receipts"), alert: e.message
  end

  private
    def set_receipt
      @receipt = Current.family.lkdr_receipts.find(params[:id])
    end
end
