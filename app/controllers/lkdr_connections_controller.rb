class LkdrConnectionsController < ApplicationController
  before_action :require_admin!
  before_action :set_connection, only: %i[verify sync destroy]

  def create
    connection = Current.family.lkdr_connection || Current.family.build_lkdr_connection
    connection.phone = params.require(:phone).strip
    connection.save!
    connection.start_challenge!(captcha_token: params.require(:captcha_token))

    redirect_to transactions_path(tab: "receipts"), notice: t("lkdr_connections.create.success")
  rescue LkdrConnection::Client::Error, KeyError, ActiveRecord::RecordInvalid => e
    redirect_to transactions_path(tab: "receipts"), alert: t("lkdr_connections.create.failure", message: e.message)
  end

  def verify
    @connection.verify!(code: params.require(:code).strip)
    redirect_to transactions_path(tab: "receipts"), notice: t("lkdr_connections.verify.success")
  rescue LkdrConnection::Client::Error, KeyError, ActiveRecord::RecordInvalid => e
    redirect_to transactions_path(tab: "receipts"), alert: t("lkdr_connections.verify.failure", message: e.message)
  end

  def sync
    @connection.sync_later
    redirect_to transactions_path(tab: "receipts"), notice: t("lkdr_connections.sync.queued")
  end

  def destroy
    @connection.destroy!
    redirect_to transactions_path(tab: "receipts"), notice: t("lkdr_connections.destroy.success")
  end

  private
    def set_connection
      @connection = Current.family.lkdr_connection
    end
end
