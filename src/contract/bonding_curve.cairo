#[starknet::contract]
mod BondingCurve {
    // Imports grouped by functionality
    use starknet::event::EventEmitter;
    use starknet::{ContractAddress, get_caller_address, get_contract_address, get_block_timestamp};
    use core::{starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess}};
    use openzeppelin_introspection::interface::{ISRC5Dispatcher, ISRC5DispatcherTrait, ISRC5_ID};
    // OpenZeppelin imports
    use openzeppelin_token::erc20::{
        ERC20Component, interface::{IERC20DispatcherTrait, IERC20Dispatcher}
    };

    // Local imports
    use crate::contract::interfaces::{
        IRouterDispatcher, IRouterDispatcherTrait, IFactoryDispatcher, IFactoryDispatcherTrait,
        IGradualLockerDispatcher, IGradualLockerDispatcherTrait, GRADUAL_LOCKER_ID, TokenLocked
    };

    use cubit::f128::types::fixed::{Fixed, FixedTrait, FixedZero};


    const TIME_OF_LOCK: u64 = 63072000;
    const MANTISSA_1e18: u256 = 1000000000000000000;
    const MANTISSA_1e12: u256 = 1000000000000;
    const MANTISSA_1e9: u256 = 1000000000;
    const MANTISSA_1e6: u256 = 1000000;


    const SCALING_FACTOR: u256 = 18446744073709552000; // 2^64 ( use with fixed.into().felt())
    // Constants
    const ETH: felt252 = 0x049d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7;

    const ROUTER_ADDRESS: felt252 =
        0x041fd22b238fa21cfcf5dd45a8548974d8263b3a531a60388411c5e230f97023;

    // Bonding curve parameters

    const MAX_SUPPLY: u256 = 1000000000 * MANTISSA_1e6;
    const TRIGGER_LAUNCH: u256 = MAX_SUPPLY * 80 / 100;
    const LP_SUPPLY: u256 = MAX_SUPPLY - TRIGGER_LAUNCH;

    // Components
    component!(path: ERC20Component, storage: erc20, event: ERC20Event);


    #[derive(Drop, PartialEq, starknet::Event)]
    pub struct BuyOrSell {
        #[key]
        pub from: ContractAddress,
        pub amount: u256,
        pub value: u256,
        pub tax: u256
    }
    #[derive(Drop, PartialEq, starknet::Event)]
    pub struct PoolLaunched {
        #[key]
        pub amount_token: u256,
        pub amount_eth: u256,
        pub amount_lp: u256,
        pub pair_address: ContractAddress,
        pub creator: ContractAddress,
    }


    // Storage
    #[storage]
    struct Storage {
        buy_tax: u16,
        sell_tax: u16,
        creator: ContractAddress,
        protocol: ContractAddress,
        controlled_market_cap: u256,
        base_price: Fixed,
        exponent: Fixed,
        step: Fixed,
        pair_address: ContractAddress,
        is_bond_closed: bool,
        #[substorage(v0)]
        erc20: ERC20Component::Storage,
        locker: ContractAddress
    }

    // Events
    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        ERC20Event: ERC20Component::Event,
        Buy: BuyOrSell,
        Sell: BuyOrSell,
        PoolLaunched: PoolLaunched,
    }

    // Implementation blocks
    #[abi(embed_v0)]
    impl ERC20Impl = ERC20Component::ERC20Impl<ContractState>;
    #[abi(embed_v0)]
    impl ERC20CamelOnlyImpl = ERC20Component::ERC20CamelOnlyImpl<ContractState>;
    impl ERC20InternalImpl = ERC20Component::InternalImpl<ContractState>;

    #[constructor]
    fn constructor(
        ref self: ContractState,
        _protocol_wallet: ContractAddress,
        _creator: ContractAddress,
        _name: ByteArray,
        _symbol: ByteArray,
        price_x1e18: felt252,
        exponent_x1e18: felt252,
        _step: u32,
        _buy_tax_percentage_x100: u16,
        _sell_tax_percentage_x100: u16,
        _locker: ContractAddress
    ) {
        let _locker_contract = IGradualLockerDispatcher { contract_address: _locker };
        // assert!(
        //     _locker_contract.supports_interface(GRADUAL_LOCKER_ID),
        //     "Locker does not support the interface"
        // );
        let mantissa: u64 = MANTISSA_1e18.try_into().unwrap();
        let _base_price = FixedTrait::from_unscaled_felt(price_x1e18) / mantissa.into();
        let _exponent = FixedTrait::from_unscaled_felt(exponent_x1e18) / mantissa.into();
        assert!(_buy_tax_percentage_x100 < 1000, "BondingCurve: Buy tax >= 10%");
        assert!(_sell_tax_percentage_x100 < 1000, "BondingCurve: Sell tax >= 10%");
        self.step.write(_step.into());
        self.base_price.write(_base_price);
        self.exponent.write(_exponent);
        self.erc20.initializer(_name, _symbol);
        self.buy_tax.write(_buy_tax_percentage_x100);
        self.sell_tax.write(_sell_tax_percentage_x100);
        self.creator.write(_creator);
        self.protocol.write(_protocol_wallet);
        self.controlled_market_cap.write(0);
        self.is_bond_closed.write(false);
        self.locker.write(_locker);
    }


    #[generate_trait]
    #[abi(per_item)]
    impl ExternalImpl of ExternalTrait {
        #[external(v0)]
        fn name(self: @ContractState) -> ByteArray {
            self.erc20.ERC20_name.read()
        }
        #[external(v0)]
        fn locker(self: @ContractState) -> ContractAddress {
            self.locker.read()
        }
        #[external(v0)]
        fn creator(self: @ContractState) -> ContractAddress {
            self.creator.read()
        }

        #[external(v0)]
        fn symbol(self: @ContractState) -> ByteArray {
            self.erc20.ERC20_symbol.read()
        }

        #[external(v0)]
        fn decimals(self: @ContractState) -> u8 {
            6
        }
        // View functions
        #[external(v0)]
        fn get_current_price(self: @ContractState) -> u256 {
            self.get_price_for_supply(self.erc20.total_supply())
        }

        #[external(v0)]
        fn get_pair(self: @ContractState) -> ContractAddress {
            self.pair_address.read()
        }

        #[external(v0)]
        fn buy_tax_percentage_x100(self: @ContractState) -> u16 {
            self.buy_tax.read()
        }

        #[external(v0)]
        fn sell_tax_percentage_x100(self: @ContractState) -> u16 {
            self.sell_tax.read()
        }

        #[external(v0)]
        fn market_cap(self: @ContractState) -> u256 {
            self.controlled_market_cap.read()
        }


        // Price calculation functions
        #[external(v0)]
        fn get_price_for_supply(self: @ContractState, supply: u256) -> u256 {
            let mantissa_1e6: Fixed = FixedTrait::from_unscaled_felt(
                MANTISSA_1e6.try_into().unwrap()
            );

            let supply_normalized: Fixed = FixedTrait::from_unscaled_felt(
                (supply).try_into().unwrap()
            )
                / mantissa_1e6; // Reduce the sze of the supply
            self._calculate_price(supply_normalized)
        }

        #[external(v0)]
        fn market_cap_for_price(self: @ContractState, price: u256) -> u256 {
            let price_normalized: Fixed = FixedTrait::from_unscaled_felt(
                (price).try_into().unwrap()
            )
                / FixedTrait::from_unscaled_felt(MANTISSA_1e18.try_into().unwrap());

            self._calculate_supply(price_normalized)
        }

        // Trade simulation functions
        #[external(v0)]
        fn simulate_buy(self: @ContractState, token_amount: u256) -> u256 {
            let (ret, _) = self._simulate_buy(token_amount);
            ret
        }

        #[external(v0)]
        fn simulate_sell(self: @ContractState, token_amount: u256) -> u256 {
            let (taxed_amount, _) = self._simulate_sell(token_amount);
            taxed_amount
        }

        #[external(v0)]
        fn get_taxes(self: @ContractState) -> (u16, u16) {
            (self.buy_tax.read().into(), self.sell_tax.read().into())
        }

        #[external(v0)]
        fn supply_advancement_percentage_x100(self: @ContractState) -> u16 {
            (self.total_supply() * 10_000 / TRIGGER_LAUNCH).try_into().expect('Supply overflow')
        }


        #[external(v0)]
        fn buy(ref self: ContractState, token_amount: u256) -> u256 {
            self.require_in_bond_stage(true);

            assert!(token_amount > 0, "BondingCurve: amount 0");
            let ts = self.erc20.total_supply();
            let is_cap_reached: bool = ts + token_amount >= TRIGGER_LAUNCH;

            let token_amount = if is_cap_reached {
                TRIGGER_LAUNCH - ts
            } else {
                token_amount
            };

            let (total_amount_eth, tax_amount) = self._simulate_buy(token_amount);
            self
                ._execute_buy(
                    total_amount_eth - tax_amount, tax_amount, token_amount, get_caller_address()
                );
            if is_cap_reached {
                self._launch_pool();
            }

            total_amount_eth
        }


        #[external(v0)]
        fn sell(ref self: ContractState, token_amount: u256) -> u256 {
            self.require_in_bond_stage(true);
            assert!(
                token_amount <= self.erc20.balance_of(get_caller_address()),
                "BondingCurve: Insufficient balance"
            );
            assert!(token_amount > 0, "BondingCurve: amount 0");
            let (amount_eth_to_send, tax) = self._simulate_sell(token_amount);
            assert!(
                self.market_cap() >= amount_eth_to_send + tax,
                "BondingCurve: Insufficient market cap"
            );
            self._execute_sell(amount_eth_to_send, tax, token_amount, get_caller_address());
            amount_eth_to_send
        }

        #[external(v0)]
        fn skim(ref self: ContractState) -> u256 {
            let eth_contract = IERC20Dispatcher { contract_address: ETH.try_into().unwrap() };
            let balance_eth = eth_contract.balance_of(get_contract_address());
            if self.market_cap() < balance_eth {
                self._transfer_tax(balance_eth - self.market_cap())
            } else {
                0
            }
        }
    }

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        fn _execute_buy(
            ref self: ContractState,
            eth_amount: u256,
            tax_amount: u256,
            mint_amount: u256,
            from: ContractAddress,
        ) {
            let eth_contract = IERC20Dispatcher { contract_address: ETH.try_into().unwrap() };
            eth_contract.transfer_from(from, get_contract_address(), eth_amount + tax_amount);
            self._transfer_tax(tax_amount);
            self._increase_market_cap(eth_amount);
            self.erc20.mint(from, mint_amount);
            self
                .emit(
                    Event::Buy(
                        BuyOrSell {
                            from: from, amount: mint_amount, value: eth_amount, tax: tax_amount
                        }
                    )
                );
        }
        fn _execute_sell(
            ref self: ContractState,
            eth_amount: u256,
            tax_amount: u256,
            token_amount: u256,
            to: ContractAddress,
        ) {
            self.erc20.burn(to, token_amount);
            let eth_contract = IERC20Dispatcher { contract_address: ETH.try_into().unwrap() };
            self._transfer_tax(tax_amount);
            self._decrease_market_cap(eth_amount + tax_amount);
            eth_contract.transfer(to, eth_amount);
            self
                .emit(
                    Event::Sell(
                        BuyOrSell {
                            from: to, amount: token_amount, value: eth_amount, tax: tax_amount
                        }
                    )
                );
        }


        fn _increase_market_cap(ref self: ContractState, amount: u256) -> u256 {
            let new_market_cap = self.controlled_market_cap.read() + amount;
            self.controlled_market_cap.write(new_market_cap);
            new_market_cap
        }

        fn _decrease_market_cap(ref self: ContractState, amount: u256) -> u256 {
            let new_market_cap = self.controlled_market_cap.read() - amount;
            self.controlled_market_cap.write(new_market_cap);
            new_market_cap
        }

        fn _launch_pool(ref self: ContractState) {
            let this_address = get_contract_address();
            self.erc20.mint(this_address, LP_SUPPLY);
            self.is_bond_closed.write(true);

            let eth_address = ETH.try_into().expect('ETH address is invalid');
            let router_address = ROUTER_ADDRESS.try_into().expect('Router address is invalid');

            let eth_contract = IERC20Dispatcher { contract_address: eth_address };
            let router_contract = IRouterDispatcher { contract_address: router_address };

            eth_contract.approve(router_address, ~0_u256);
            self.erc20._approve(this_address, router_address, ~0_u256);

            let (amount_a, amount_b, amount_lp) = router_contract
                .add_liquidity(
                    eth_address,
                    this_address,
                    self.market_cap(),
                    LP_SUPPLY,
                    0,
                    0,
                    this_address,
                    18446744073709552000
                );
            let factory_address = IFactoryDispatcher {
                contract_address: router_contract.factory()
            };

            let pair_address = factory_address.get_pair(eth_address, this_address);
            self.pair_address.write(pair_address);
            let locker_contract = IGradualLockerDispatcher { contract_address: self.locker.read() };
            let pair_contract = IERC20Dispatcher { contract_address: pair_address };
            pair_contract.approve(self.locker.read(), amount_lp);
            let end_time: u64 = get_block_timestamp().try_into().unwrap() + TIME_OF_LOCK;
            let token_locked: TokenLocked = locker_contract
                .lockCamel(pair_address, amount_lp, end_time, self.protocol.read());
            assert!(
                token_locked.current_amount == amount_lp, "Locker did not lock the correct amount"
            );
            self
                .emit(
                    Event::PoolLaunched(
                        PoolLaunched {
                            amount_token: amount_b,
                            amount_eth: amount_a,
                            amount_lp: amount_lp,
                            pair_address,
                            creator: self.creator.read()
                        }
                    )
                );
            let rests = eth_contract.balance_of(this_address);
            if rests > 0 {
                self._transfer_tax(rests);
            }
        }


        /// Internal functions READ

        fn _calculate_supply(self: @ContractState, price: Fixed,) -> u256 {
            let (_, base_normalized, exponent_normalized) = self._get_price_consts();
            let mantissa_1e6 = FixedTrait::from_unscaled_felt(MANTISSA_1e6.try_into().unwrap());

            let ln_result = (price / (base_normalized)).ln();
            let supply: Fixed = ((ln_result / exponent_normalized) * self.step.read());

            let supply_scaled_with_6_decimal: felt252 = (supply * mantissa_1e6).round().into();

            supply_scaled_with_6_decimal.into() / SCALING_FACTOR
        }

        fn _calculate_price(self: @ContractState, supply: Fixed) -> u256 {
            let (mantissa_1e9, base_normalized, exponent_normalized) = self._get_price_consts();

            // Calculate normalized supply * exponent
            let y_calc = supply / self.step.read() * exponent_normalized;
            let exp_result = (y_calc).exp();

            // Scale result
            let price_fixed: Fixed = (base_normalized * exp_result);

            let price_scaled_with_18_decimals: felt252 = (price_fixed * mantissa_1e9 * mantissa_1e9)
                .round()
                .into();

            price_scaled_with_18_decimals.into() / SCALING_FACTOR
        }

        fn _calculate_average_price(
            self: @ContractState, supply_start: Fixed, supply_end: Fixed,
        ) -> u256 {
            let mantissa_1e9: Fixed = FixedTrait::from_unscaled_felt(
                MANTISSA_1e9.try_into().unwrap()
            );
            let step: Fixed = self.step.read();
            let base = self.base_price.read();
            let exponent = self.exponent.read();

            // Calculate normalized supplies * exponent
            let y_calc_end = supply_end / step * exponent;
            let exp_result_end = (y_calc_end).exp();
            let y_calc_start = supply_start / step * exponent;
            let exp_result_start = (y_calc_start).exp();

            // Calculate absolute difference of exponentials
            let exp_diff = if exp_result_end >= exp_result_start {
                exp_result_end - exp_result_start
            } else {
                exp_result_start - exp_result_end
            };

            // Calculate absolute supply difference
            let supply_diff = if supply_end >= supply_start {
                supply_end - supply_start
            } else {
                supply_start - supply_end
            };

            // Calculate integral using step/exponent factor and base
            let factor = step / exponent;
            let average = base * factor * exp_diff / supply_diff;

            // Scale result
            let ret_scaled: felt252 = (average * mantissa_1e9 * mantissa_1e9).round().into();
            ret_scaled.into() / SCALING_FACTOR
        }


        fn _get_price_consts(self: @ContractState) -> (Fixed, Fixed, Fixed) {
            let mantissa_1e9: Fixed = FixedTrait::from_unscaled_felt(
                MANTISSA_1e9.try_into().unwrap()
            );

            (mantissa_1e9, self.base_price.read(), self.exponent.read())
        }
        fn require_in_bond_stage(self: @ContractState, is_it: bool) {
            let is_bond_closed = self.is_bond_closed.read();
            if !is_it {
                assert!(is_bond_closed, "Bonding stage is closed");
            } else {
                assert!(!is_bond_closed, "Bonding stage is still open");
            }
        }


        fn _simulate_sell(self: @ContractState, token_amount: u256) -> (u256, u256) {
            let current_supply = self._normalize_token(self.erc20.total_supply());
            let normalized_token_amount = self._normalize_token(token_amount);
            if current_supply < normalized_token_amount {
                return (0, 0);
            };

            let new_supply = current_supply - normalized_token_amount;
            let av_price = self._calculate_average_price(current_supply, new_supply);

            let eth_amount = token_amount
                * av_price
                / MANTISSA_1e6; //Here the mantissa_1e6 because token decimals  6 but price and ether is 18
            self._simulate_sell_tax(eth_amount)
        }

        fn _simulate_buy(self: @ContractState, desired_tokens: u256) -> (u256, u256) {
            let current_supply = self._normalize_token(self.erc20.total_supply());
            let normalized_desired_tokens = self._normalize_token(desired_tokens);

            let new_supply = current_supply + normalized_desired_tokens;
            let av_price = self._calculate_average_price(current_supply, new_supply);

            let eth_needed = desired_tokens
                * av_price
                / MANTISSA_1e6; //Here the mantissa_1e6 because token decimals  6 but price and ether is 18
            self._simulate_buy_tax(eth_needed)
        }
        fn _simulate_buy_tax(self: @ContractState, amount: u256) -> (u256, u256) {
            let tax_amount = amount * self.buy_tax.read().into() / 10000_u256;
            (amount + tax_amount, tax_amount)
        }
        fn _simulate_sell_tax(self: @ContractState, amount: u256) -> (u256, u256) {
            let tax = amount * self.sell_tax.read().into() / 10000;
            (amount - tax, tax)
        }

        fn _transfer_tax(self: @ContractState, amount: u256) -> u256 {
            let eth_contract = IERC20Dispatcher { contract_address: ETH.try_into().unwrap() };
            eth_contract.transfer(self.protocol.read(), amount);
            amount
        }
        fn _normalize_token(self: @ContractState, token_amount: u256) -> Fixed {
            let mantissa_1e6: Fixed = FixedTrait::from_unscaled_felt(
                MANTISSA_1e6.try_into().unwrap()
            );
            FixedTrait::from_unscaled_felt(token_amount.try_into().unwrap()) / mantissa_1e6
        }
        fn _normalize_ether(self: @ContractState, wei_amount: u256) -> Fixed {
            let mantissa_1e9: Fixed = FixedTrait::from_unscaled_felt(
                MANTISSA_1e9.try_into().unwrap()
            );
            let gwei_amount = (wei_amount / MANTISSA_1e9).try_into().unwrap();
            FixedTrait::from_unscaled_felt(gwei_amount) / mantissa_1e9
        }
    }

    /// Hooks
    pub impl ERC20Hooks of ERC20Component::ERC20HooksTrait<ContractState> {
        fn before_update(
            ref self: ERC20Component::ComponentState<ContractState>,
            from: ContractAddress,
            recipient: ContractAddress,
            amount: u256
        ) {
            if 0 != recipient.into() && 0 != from.into() {
                let contract_state = self.get_contract();
                if !contract_state.is_bond_closed.read() {
                    let recipient = ISRC5Dispatcher { contract_address: recipient };
                    assert!(
                        recipient.supports_interface(ISRC5_ID),
                        "LFTCRV: Non account transfer during bonding phase"
                    );
                }
            }
        }

        fn after_update(
            ref self: ERC20Component::ComponentState<ContractState>,
            from: ContractAddress,
            recipient: ContractAddress,
            amount: u256
        ) {}
    }
}
