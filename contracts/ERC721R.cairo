%lang starknet

from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.starknet.common.syscalls import (
    get_caller_address, get_contract_address, get_block_number)

from starkware.cairo.common.uint256 import (
    Uint256, uint256_lt, uint256_le, uint256_check)

from starkware.cairo.common.math import (
    assert_le, assert_lt, assert_not_zero)

from starkware.cairo.common.math_cmp import is_le 
from starkware.cairo.common.pow import pow 

from openzeppelin.access.ownable import (
    Ownable_initializer, Ownable_get_owner, Ownable_only_owner)

from openzeppelin.token.erc721.library import (
    ERC721_balanceOf, ERC721_ownerOf, ERC721_getApproved, ERC721_name, ERC721_symbol,
    ERC721_isApprovedForAll, ERC721_tokenURI, ERC721_initializer, ERC721_approve,
    ERC721_setApprovalForAll, ERC721_transferFrom, ERC721_safeTransferFrom, ERC721_mint,
    ERC721_burn, ERC721_only_token_owner, ERC721_setTokenURI)

from openzeppelin.introspection.ERC165 import ERC165_supports_interface
from openzeppelin.token.erc20.interfaces.IERC20 import IERC20
from openzeppelin.security.safemath import (
    uint256_checked_add, uint256_checked_sub_le, uint256_checked_mul)
from src.openzeppelin.security.reentrancy_guard import (ReentrancyGuard_start, ReentrancyGuard_end)

# the current token ID to be minted
@storage_var
func ERC721R_current_token_id() -> (token_id : Uint256):
end

# the max amount of tokens that can ever be minted
@storage_var
func ERC721R_max_supply() -> (supply : Uint256):
end

# price for each token
@storage_var
func ERC721R_mint_price() -> (price : Uint256):
end

# how long is the refund period
@storage_var
func ERC721R_refund_period() -> (period : felt):
end

# how many tokens have been minted
@storage_var
func ERC721R_amount_minted() -> (amount : Uint256):
end

# when does the refund end
@storage_var
func ERC721R_refund_end_time() -> (end_time : felt):
end

# the address to hold the refunded NFTs
@storage_var
func ERC721R_refund_address() -> (address : felt):
end

# the max amount users can mint each
@storage_var
func ERC721R_max_user_mint_amount() -> (amount : Uint256):
end

# the amount minted by a certain account
@storage_var
func ERC721R_user_minted_amount(account : felt) -> (amount : Uint256):
end

# check if the token was refunded
@storage_var
func ERC721R_was_refunded(token_id : Uint256) -> (refunded : felt):
end

# the address of the token used to pay for the NFT
@storage_var
func ERC721R_mint_currency() -> (token_address : felt):
end

@constructor
func constructor{
    syscall_ptr : felt*, 
    pedersen_ptr : HashBuiltin*, 
    range_check_ptr
    }(
    owner : felt, 
    refund_address : felt,
    refund_period : felt,
    name : felt, 
    symbol : felt,
    currency_token : felt, 
    mint_price : Uint256, 
    max_amount_per_user : Uint256,
    max_supply : Uint256
    ):
    # set owner
    Ownable_initializer(owner)
    # set ERC721 properties
    ERC721_initializer(name, symbol)
    # write the refund address
    with_attr error_message("ERC721R: Refund address cannot be zero"):
        assert_not_zero(refund_address)
    end 
    ERC721R_refund_address.write(refund_address)
    # set the currency for the mint
    ERC721R_mint_currency.write(currency_token)
    # set mint price
    with_attr error_message("ERC721: The mint price is not a valid Uint256"):
        uint256_check(mint_price)
    end
    set_mint_price(mint_price)
    # set max supply
    with_attr error_message("ERC721: The max supply is not a valid Uint256"):
        uint256_check(max_supply)
    end
    ERC721R_max_supply.write(max_supply)
    # set max amount per user
    with_attr error_message("ERC721: The max amount per user is not a valid Uint256"):
        uint256_check(max_amount_per_user)
    end
    ERC721R_max_user_mint_amount.write(max_amount_per_user)
    # set the refund end time
    ERC721R_refund_period.write(refund_period)
    toggle_refund_time()
    return ()
end

####
#### Internal Functions
####

# sets the mint price with the appropriate token decimals 
func set_mint_price{
    syscall_ptr : felt*, 
    pedersen_ptr : HashBuiltin*, 
    range_check_ptr
    }(mint_price : Uint256):
    alloc_locals
    let (local token_address) = ERC721R_mint_currency.read()
    let (local decimals) = IERC20.decimals(contract_address=token_address)
    let (local exponential) = pow(10, decimals)
    local exponential_uint256 : Uint256 = Uint256(exponential, 0)
    let (local amount : Uint256) = uint256_checked_mul(mint_price, exponential_uint256)
    ERC721R_mint_price.write(amount)
    return ()
end 

# internal function so won't be added access control check
# this helps with the deployment of the contract 
# as we can deploy as a different owner 
func toggle_refund_time{
    syscall_ptr : felt*, 
    pedersen_ptr : HashBuiltin*, 
    range_check_ptr
    }():
    let (block_number) = get_block_number()
    let (refund_period) = ERC721R_refund_period.read()
    ERC721R_refund_end_time.write(block_number + refund_period)
    return ()
end

# internal function that acts as a for loop for NFTs 
func nft_transfer{
    syscall_ptr : felt*, 
    pedersen_ptr : HashBuiltin*, 
    range_check_ptr
    }(
    mint_price : Uint256, 
    refund_address : felt, 
    account : felt, 
    token_ids_len : felt,
    token_ids : felt*
    ) -> (sum : Uint256):
    alloc_locals
    local zero : Uint256 = Uint256(0, 0)
    if token_ids_len == 0:
        return (sum=zero)
    end

    local token_id_uint256 : Uint256 = Uint256([token_ids], 0)

    # let's check if we own the token we are trying to refund 
    # here we could fail directly or try the transfer (which will fail later)
    # I'd say we just fail now 
    with_attr error_mesage("ERC721R: You cannot refund someone's else token"):
        let (local real_owner) = ERC721_ownerOf(token_id_uint256)
        assert real_owner = account 
    end 

    # call itself moving forward one slot
    let (local current_sum : Uint256) = nft_transfer(
        mint_price=mint_price,
        refund_address=refund_address,
        account=account,
        token_ids_len=token_ids_len - 1,
        token_ids=token_ids + 1)

    # check if the token was refunded already
    # here we can fail the whole transaction or
    # continue and calculate the refund amount of what can be refunded
    # anyways transferring a token which is not owned by the caller
    # would fail
    let (local was_refunded) = ERC721R_was_refunded.read(token_id_uint256)
    # we will continue and not transfer this neither calculate the amount
    # revoked references
    tempvar syscall_ptr = syscall_ptr
    tempvar pedersen_ptr = pedersen_ptr
    tempvar range_check_ptr = range_check_ptr
    
    if was_refunded == 0:
        # send NFT to decided refund address
        ERC721_transferFrom(from_=account, to=refund_address, token_id=token_id_uint256)
        #ERC721_safeTransferFrom(from_=account,to=refund_address,token_id=token_id_uint256, data_len=0, data=&[0])
        # set the token as refunded
        ERC721R_was_refunded.write(token_id=token_id_uint256, value=1)
        # now add to the sum
        let (local sum : Uint256) = uint256_checked_add(mint_price, current_sum)
        # return the sum
        return (sum)
    end
    # if the item was already refunded, we just return the current sum
    return (current_sum)
end

# internal mint function 
func _mint{
    syscall_ptr : felt*, 
    pedersen_ptr : HashBuiltin*, 
    range_check_ptr
    }(
        caller_address : felt,
        tokens_len : felt,  
    ):
    alloc_locals 
    # if we are at the last element you don't need to mint anymore, just return 
    if tokens_len == 0:
        return ()
    end 

    let (local current_token_id : Uint256) = ERC721R_current_token_id.read()
    # mint 
    ERC721_mint(caller_address, current_token_id)
    # increase token ID 
    local one : Uint256 = Uint256(1, 0)
    let (local new_token_id : Uint256) = uint256_checked_add(current_token_id, one)
    ERC721R_current_token_id.write(new_token_id)

    _mint(caller_address, tokens_len-1)
   
    return ()
end 

# check if the refund period is still on
func is_refund_guarantee_active{
    syscall_ptr : felt*, 
    pedersen_ptr : HashBuiltin*, 
    range_check_ptr
    }():
    alloc_locals
    let (local block_number) = get_block_number()
    let (local refund_end_time) = ERC721R_refund_end_time.read()

    with_attr error_message("ERC721R: the guaranteed refund period has ended"):
        assert_le(block_number, refund_end_time)
    end

    return ()
end

###
### External Functions
###

@external
func refund{
    syscall_ptr : felt*, 
    pedersen_ptr : HashBuiltin*, 
    range_check_ptr
    }(
    token_ids_len : felt, 
    token_ids : felt*
    ):
    alloc_locals
    # check if we are still in time for refund - this will throw a failure
    # we only check once as if the period ends while someone started the refund
    # I think it's fair to be ok with it
    # one could add the check on the internal function to only refund x amount of tokens
    ReentrancyGuard_start()
    
    is_refund_guarantee_active()
    
    # get the caller address
    let (local caller_address) = get_caller_address()
    # get refund address
    let (local refund_address) = ERC721R_refund_address.read()
    # get currency address
    let (local currency_token) = ERC721R_mint_currency.read()
    # get mint price
    let (local mint_price) = ERC721R_mint_price.read()

    # get the sum of money to send
    let (amount_to_refund : Uint256) = nft_transfer(
        mint_price=mint_price,
        refund_address=refund_address,
        account=caller_address,
        token_ids_len=token_ids_len,
        token_ids=token_ids)

    # refund
    IERC20.transfer(
        contract_address=currency_token, recipient=caller_address, amount=amount_to_refund)

    ReentrancyGuard_end()
    return ()
end

@external
func mint{
    syscall_ptr : felt*, 
    pedersen_ptr : HashBuiltin*, 
    range_check_ptr
    }(
    quantity : Uint256) -> ():
    alloc_locals

    ReentrancyGuard_start()

    # check if we are already at max supply
    let (local max_mint_supply) = ERC721R_max_supply.read()
    let (local current_supply) = ERC721R_amount_minted.read()
    let (local new_supply) = uint256_checked_add(current_supply, quantity)
    with_attr error_mesage("ERC721R: Max supply reached"):
        let (local result) = uint256_le(new_supply, max_mint_supply)
        assert result = 1
    end

    # check that the user didn't mint more than allowed
    let (local caller_address) = get_caller_address()
    let (local amount_minted : Uint256) = ERC721R_user_minted_amount.read(caller_address)
    let (local max_user_mint_amount : Uint256) = ERC721R_max_user_mint_amount.read()
    let (local tmp_quantity : Uint256) = uint256_checked_add(quantity, amount_minted)
    with_attr error_message("ERC721R: You cannot mint more than the max amount per user"):
        let (local result) = uint256_le(tmp_quantity, max_user_mint_amount)
        assert result = 1
    end

    # get funds
    let (local token_address) = ERC721R_mint_currency.read()
    let (local self) = get_contract_address()
    # get the price for all mints 
    let (local amount : Uint256) = total_mint_price(quantity)
    # Users will need to approve first 
    # we can add a check here to error out with a nice message
    let (local allowance : Uint256) = IERC20.allowance(
        contract_address=token_address, 
        owner=caller_address,
        spender=self
        )
    with_attr error_mesage("ERC721R: You need to approve the contract to spend at least the mint price * quantity minted"):
        let (local result) = uint256_le(amount, allowance)
        assert result = 1 
    end 
    IERC20.transferFrom(
        contract_address=token_address, 
        sender=caller_address, 
        recipient=self, 
        amount=amount
        )

    # We are increasing here instead of increasing once every iteration of _mint to save writes 
    # anyways we checked before that the max supply and the max per user are ok 
    # increase minted token supply
    let (local new_minted_amount : Uint256) = uint256_checked_add(current_supply, quantity)
    ERC721R_amount_minted.write(new_minted_amount)
    # increase amount minted for the user
    let (local new_user_amount_minted : Uint256) = uint256_checked_add(amount_minted, quantity)
    ERC721R_user_minted_amount.write(caller_address, new_user_amount_minted)

    # internal mint function 
    _mint(caller_address, quantity.low)


    ReentrancyGuard_end()
    # revoked references
    tempvar syscall_ptr = syscall_ptr
    tempvar pedersen_ptr = pedersen_ptr
    tempvar range_check_ptr = range_check_ptr

    return ()
end

@external
func withdraw{
    syscall_ptr : felt*, 
    pedersen_ptr : HashBuiltin*, 
    range_check_ptr
    }():
    alloc_locals
    # only owner can withdraw funds
    Ownable_only_owner()

    ReentrancyGuard_start()
    # check if we are past the refund period
    let (local block_number) = get_block_number()
    let (local refund_end_time) = ERC721R_refund_end_time.read()
    with_attr error_message("ERC721R: Refund period is not over"):
        assert_lt(refund_end_time, block_number)
    end

    # get balance of contract
    let (local self) = get_contract_address()
    let (local token_address) = ERC721R_mint_currency.read()
    let (local contract_balance : Uint256) = IERC20.balanceOf(
        contract_address=token_address, account=self)

    # send the tokens to the owner
    let (owner) = Ownable_get_owner()
    IERC20.transfer(contract_address=token_address, recipient=owner, amount=contract_balance)

    ReentrancyGuard_end()
    return ()
end

# # custom burn function
# will need to reset the maxSupply to maxSupply - 1
@external
func burn{
    syscall_ptr : felt*, 
    pedersen_ptr : HashBuiltin*, 
    range_check_ptr
    }(token_id : Uint256):
    alloc_locals

    # check that the caller is the owner 
    ERC721_only_token_owner(token_id)

    # reduce the maxSupply
    let (local current_max_supply : Uint256) = ERC721R_max_supply.read()
    local one : Uint256 = Uint256(1, 0)
    let (local new_supply : Uint256) = uint256_checked_sub_le(current_max_supply, one)
    ERC721R_max_supply.write(value=new_supply)

    # don't think there's need to set the token ID as refunded

    # burn it
    ERC721_burn(token_id)

    return ()
end

# approve for transfer 
@external
func approve{
        pedersen_ptr: HashBuiltin*, 
        syscall_ptr: felt*, 
        range_check_ptr
    }(to: felt, tokenId: Uint256):
    ERC721_approve(to, tokenId)
    return ()
end

@external
func setApprovalForAll{
        syscall_ptr: felt*, 
        pedersen_ptr: HashBuiltin*, 
        range_check_ptr
    }(operator: felt, approved: felt):
    ERC721_setApprovalForAll(operator, approved)
    return ()
end

@external
func transferFrom{
        pedersen_ptr: HashBuiltin*, 
        syscall_ptr: felt*, 
        range_check_ptr
    }(
        from_: felt, 
        to: felt, 
        tokenId: Uint256
    ):
    ERC721_transferFrom(from_, to, tokenId)
    return ()
end

@external
func safeTransferFrom{
        pedersen_ptr: HashBuiltin*, 
        syscall_ptr: felt*, 
        range_check_ptr
    }(
        from_: felt, 
        to: felt, 
        tokenId: Uint256,
        data_len: felt, 
        data: felt*
    ):
    ERC721_safeTransferFrom(from_, to, tokenId, data_len, data)
    return ()
end

@external
func setTokenURI{
        pedersen_ptr: HashBuiltin*, 
        syscall_ptr: felt*, 
        range_check_ptr
    }(tokenId: Uint256, tokenURI: felt):
    Ownable_only_owner()
    ERC721_setTokenURI(tokenId, tokenURI)
    return ()
end

###
### View Functions 
###

# get the refund end time 
@view
func refund_end_time{
    syscall_ptr : felt*, 
    pedersen_ptr : HashBuiltin*, 
    range_check_ptr
    }() -> (end_time : felt):
    let (refund_end_time) = ERC721R_refund_end_time.read()
    return (refund_end_time)
end

# get the max supply 
@view 
func maxSupply{
    syscall_ptr : felt*, 
    pedersen_ptr : HashBuiltin*, 
    range_check_ptr
    }() -> (max_supply : Uint256):
    let (max_supply) = ERC721R_max_supply.read()
    return (max_supply)
end 

# check how many tokens were minted so far 
@view 
func minted_amount{
    syscall_ptr : felt*, 
    pedersen_ptr : HashBuiltin*, 
    range_check_ptr
    }() -> (current_minted_supply : Uint256):
    let (current_minted_supply) = ERC721R_amount_minted.read()
    return (current_minted_supply)
end 

# For transparency get the address to where refunds are made 
@view 
func refund_address{
    syscall_ptr : felt*, 
    pedersen_ptr : HashBuiltin*, 
    range_check_ptr
    }() -> (refund_address : felt):
    let (refund_address) = ERC721R_refund_address.read()
    return (refund_address)
end 

# get the mint price
@view 
func mint_price{
    syscall_ptr : felt*, 
    pedersen_ptr : HashBuiltin*, 
    range_check_ptr
    }() -> (mint_price : Uint256):
    let (mint_price : Uint256) = ERC721R_mint_price.read()
    return (mint_price)
end 

# get the currency address
@view 
func currency_address{
    syscall_ptr : felt*, 
    pedersen_ptr : HashBuiltin*, 
    range_check_ptr
    }() -> (currency_address : felt):
    let (currency_address) = ERC721R_mint_currency.read()
    return (currency_address)
end 

# get the max amount of tokens an user can mint
@view 
func max_user_mint_amount{
    syscall_ptr : felt*, 
    pedersen_ptr : HashBuiltin*, 
    range_check_ptr
    }() -> (max_user_mint_amount : Uint256):
    let (max_user_mint_amount : Uint256) = ERC721R_max_user_mint_amount.read()
    return (max_user_mint_amount)
end 

# get the amount of NFTs an account has minted
@view 
func user_minted_amount{
    syscall_ptr : felt*, 
    pedersen_ptr : HashBuiltin*, 
    range_check_ptr
    }(account : felt) -> (amount : Uint256):
    let (user_minted_amount : Uint256) = ERC721R_user_minted_amount.read(account)
    return (user_minted_amount)
end 

# get the price to mint x NFTs
@view 
func total_mint_price{
    syscall_ptr : felt*, 
    pedersen_ptr : HashBuiltin*, 
    range_check_ptr
    }(quantity : Uint256) -> (amount : Uint256):
    alloc_locals 

    # calculate price 
    let (local mint_price : Uint256) = ERC721R_mint_price.read()
    let (local amount : Uint256) = uint256_checked_mul(quantity, mint_price)
    return (amount)
end 

# check if a token was refunded or not
@view 
func was_refunded{
    syscall_ptr : felt*, 
    pedersen_ptr : HashBuiltin*, 
    range_check_ptr
    }(token_id : Uint256) -> (was_refunded : felt):
    alloc_locals

    with_attr error_message("ERC721R: token_id is not a valid Uint256"):
        uint256_check(token_id)
    end 

    # check that the token ID is within the minted amount 
    let (local minted_supply : Uint256) = ERC721R_amount_minted.read()
    with_attr error("ERC721R: No NFTs were minted yet"):
        assert_not_zero(minted_supply.low)
    end 

    with_attr error_message("ERC721R: token_id does not exist"):
        let (local result) = uint256_le(token_id, minted_supply)
        assert result = 1
    end 

    let (was_refunded) = ERC721R_was_refunded.read(token_id)

    # revoked references
    tempvar syscall_ptr = syscall_ptr
    tempvar pedersen_ptr = pedersen_ptr
    tempvar range_check_ptr = range_check_ptr
    return (was_refunded)
end 

@view
func supportsInterface{
        syscall_ptr : felt*,
        pedersen_ptr : HashBuiltin*,
        range_check_ptr
    }(interfaceId: felt) -> (success: felt):
    let (success) = ERC165_supports_interface(interfaceId)
    return (success)
end

# check if the refund period ended 
@view 
func is_refund_period_ended{
        syscall_ptr : felt*,
        pedersen_ptr : HashBuiltin*,
        range_check_ptr
    } () -> (ended : felt):
    alloc_locals
    
    let (local block_number) = get_block_number()
    let (local refund_end_time) = ERC721R_refund_end_time.read()

    let (ended) = is_le(block_number, refund_end_time)

    # if the current block number is less than the end time return 0 as false
    if ended == 1:
        return (0)
    end 
    # otherwise return 1 as true 
    return (1)

end 

# get the next token ID that will be minted
@view 
func current_token_id{
        syscall_ptr : felt*, 
        pedersen_ptr : HashBuiltin*,
        range_check_ptr
    }() -> (id : Uint256):
    let (token_id : Uint256) = ERC721R_current_token_id.read()
    return (token_id)
end 

# get the owner of a NFT 
@view
func ownerOf{
        syscall_ptr : felt*, 
        pedersen_ptr : HashBuiltin*,
        range_check_ptr
    }(tokenId: Uint256) -> (owner: felt):
    let (owner: felt) = ERC721_ownerOf(tokenId)
    return (owner)
end

# get the NFT balance of an address
@view
func balanceOf{
        syscall_ptr : felt*, 
        pedersen_ptr : HashBuiltin*,
        range_check_ptr
    }(owner: felt) -> (balance: Uint256):
    let (balance: Uint256) = ERC721_balanceOf(owner)
    return (balance)
end

# get the name of the NFT 
@view
func name{
        syscall_ptr : felt*,
        pedersen_ptr : HashBuiltin*,
        range_check_ptr
    }() -> (name: felt):
    let (name) = ERC721_name()
    return (name)
end

# get the symbol of the NFT
@view
func symbol{
        syscall_ptr : felt*,
        pedersen_ptr : HashBuiltin*,
        range_check_ptr
    }() -> (symbol: felt):
    let (symbol) = ERC721_symbol()
    return (symbol)
end

# chek if the token is approved
@view
func getApproved{
        syscall_ptr : felt*, 
        pedersen_ptr : HashBuiltin*,
        range_check_ptr
    }(tokenId: Uint256) -> (approved: felt):
    let (approved: felt) = ERC721_getApproved(tokenId)
    return (approved)
end

# check is approved for all 
@view
func isApprovedForAll{
        syscall_ptr : felt*, 
        pedersen_ptr : HashBuiltin*,
        range_check_ptr
    }(owner: felt, operator: felt) -> (isApproved: felt):
    let (isApproved: felt) = ERC721_isApprovedForAll(owner, operator)
    return (isApproved)
end

# get the token URI 
@view
func tokenURI{
        syscall_ptr: felt*, 
        pedersen_ptr: HashBuiltin*, 
        range_check_ptr
    }(tokenId: Uint256) -> (tokenURI: felt):
    let (tokenURI: felt) = ERC721_tokenURI(tokenId)
    return (tokenURI)
end

# get the owner of the contract 
@view
func get_owner{
        syscall_ptr : felt*, 
        pedersen_ptr : HashBuiltin*,
        range_check_ptr
    }() -> (owner: felt):
    let (owner) = Ownable_get_owner()
    return (owner=owner)
end