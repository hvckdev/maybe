# frozen_string_literal: true

require "test_helper"

class TinkoffAccount::ProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    # TODO: Create or reference your tinkoff_item fixture
    # @tinkoff_item = tinkoff_items(:configured_item)
    # @tinkoff_account = tinkoff_accounts(:test_account)

    # Create a linked Sure account for the provider account
    @account = @family.accounts.create!(
      name: "Test Account",
      balance: 10000,
      currency: "USD",
      accountable: Depository.new
    )

    # TODO: Link the provider account to the Sure account
    # @tinkoff_account.ensure_account_provider!(@account)
    # @tinkoff_account.reload
  end

  # ==========================================================================
  # Processor tests
  # ==========================================================================

  test "processor initializes with tinkoff_account" do
    skip "TODO: Set up tinkoff_account fixture"

    # processor = TinkoffAccount::Processor.new(@tinkoff_account)
    # assert_not_nil processor
  end

  test "processor skips processing when no linked account" do
    skip "TODO: Set up tinkoff_account fixture"

    # Remove the account provider link
    # @tinkoff_account.account_provider&.destroy
    # @tinkoff_account.reload

    # processor = TinkoffAccount::Processor.new(@tinkoff_account)
    # assert_nothing_raised { processor.process }
  end

  test "processor updates account balance" do
    skip "TODO: Set up tinkoff_account fixture"

    # @tinkoff_account.update!(current_balance: 15000)
    #
    # processor = TinkoffAccount::Processor.new(@tinkoff_account)
    # processor.process
    #
    # @account.reload
    # assert_equal 15000, @account.balance.to_f
  end

  # ==========================================================================
  # TransactionsProcessor tests
  # ==========================================================================

  test "transactions processor creates entries from raw payload" do
    skip "TODO: Set up tinkoff_account fixture and transactions payload"

    # @tinkoff_account.update!(raw_transactions_payload: [
    #   {
    #     "id" => "txn_001",
    #     "amount" => 50.00,
    #     "date" => Date.current.to_s,
    #     "name" => "Coffee Shop",
    #     "pending" => false
    #   }
    # ])
    #
    # processor = TinkoffAccount::Transactions::Processor.new(@tinkoff_account)
    # result = processor.process
    #
    # assert result[:success]
    # assert_equal 1, result[:imported]
  end

  test "transactions processor handles missing transaction id gracefully" do
    skip "TODO: Set up tinkoff_account fixture"

    # @tinkoff_account.update!(raw_transactions_payload: [
    #   { "id" => nil, "amount" => 50.00, "date" => Date.current.to_s }
    # ])
    #
    # processor = TinkoffAccount::Transactions::Processor.new(@tinkoff_account)
    # result = processor.process
    #
    # assert_equal 1, result[:failed]
  end

  test "transactions processor returns empty result when no transactions" do
    skip "TODO: Set up tinkoff_account fixture"

    # @tinkoff_account.update!(raw_transactions_payload: [])
    #
    # processor = TinkoffAccount::Transactions::Processor.new(@tinkoff_account)
    # result = processor.process
    #
    # assert result[:success]
    # assert_equal 0, result[:total]
  end
end
