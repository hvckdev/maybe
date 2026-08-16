require "test_helper"

class LkdrConnectionTest < ActiveSupport::TestCase
  setup do
    @connection = families(:empty).create_lkdr_connection!(phone: "+79990000000")
  end

  test "stores tokens only after SMS verification" do
    LkdrConnection::Client.any_instance.expects(:start_challenge).with(phone: "+79990000000", captcha_token: "captcha-token").returns(
      "challengeToken" => "challenge-token",
      "challengeTokenExpiresIn" => 5.minutes.from_now.iso8601
    )
    @connection.start_challenge!(captcha_token: "captcha-token")

    LkdrConnection::Client.any_instance.expects(:verify_challenge).with(
      challenge_token: "challenge-token",
      phone: "+79990000000",
      code: "123456"
    ).returns("refreshToken" => "refresh-token")

    @connection.verify!(code: "123456")

    assert @connection.connected?
    assert_equal "refresh-token", @connection.refresh_token
    assert_nil @connection.challenge_token
  end

  test "syncs receipts using the refreshed access token" do
    @connection.update!(refresh_token: "refresh-token", status: :connected)
    LkdrConnection::Client.any_instance.expects(:refresh).with(refresh_token: "refresh-token").returns("token" => "access-token")
    LkdrConnection::Client.any_instance.expects(:receipts).with(access_token: "access-token", offset: 0).returns(
      "receipts" => [ {
        "key" => "receipt-key",
        "kktOwner" => "Coffee Shop",
        "kktOwnerInn" => "7701234567",
        "createdDate" => "2026-08-08T12:00:00",
        "totalSum" => "249.50",
        "fiscalDriveNumber" => "9999999999999999",
        "fiscalDocumentNumber" => "42"
      } ],
      "hasMore" => false
    )

    assert_difference "LkdrReceipt.count", 1 do
      @connection.sync_receipts!
    end

    receipt = @connection.family.lkdr_receipts.find_by!(external_key: "receipt-key")
    assert_equal "Coffee Shop", receipt.merchant_name
    assert_equal 249.50.to_d, receipt.total_amount
    assert @connection.connected?
  end
end
