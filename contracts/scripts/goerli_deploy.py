from brownie import *
import time
import pytest

GAS_LIMIT = 6721975

def main():
    owner = accounts.load('goerli')
    deployer = accounts.load('goerli-deployer')
    ethDepositContract = "0x07b39f4fde4a38bace212b546dac87c58dfe3fdc"
    withdrawalCredential = "0059114a87b004550c90a185fe9318fccfe3c2cdaf87a9f1345e52b9eb720dfc"

    print(f'contract owner account: {owner.address}\n')

    xETH_contract = RockXETH.deploy(
        {'from': deployer, 'gas': GAS_LIMIT}
    )

    xETH_proxy = TransparentUpgradeableProxy.deploy(
        xETH_contract, deployer, b'',
        {'from': deployer, 'gas': GAS_LIMIT}
    )

    staking_contract = RockXStaking.deploy(
        {'from': deployer, 'gas': GAS_LIMIT}
    )

    staking_proxy = TransparentUpgradeableProxy.deploy(
        staking_contract, deployer, b'',
        {'from': deployer, 'gas': GAS_LIMIT}
    )
  
    transparent_xeth = Contract.from_abi("RockXETH", xETH_contract.address, RockXETH.abi)
    transparent_staking = Contract.from_abi("RockXStaking",staking_proxy.address, RockXStaking.abi)

    transparent_xeth.initialize(
        {'from': owner, 'gas': GAS_LIMIT}
    )
    transparent_xeth.setMintable(
        staking_proxy, True,
        {'from': owner, 'gas': GAS_LIMIT}
    )

    transparent_staking.initialize(
        {'from': owner, 'gas': GAS_LIMIT}
    ) 

    transparent_staking.setXETHContractAddress(
        transparent_xeth,
        {'from': owner, 'gas': GAS_LIMIT}
    )

    transparent_staking.setDepositSize(
        '1 ether',
        {'from': owner, 'gas': GAS_LIMIT}
    )


    transparent_staking.setETHDepositContract(
        ethDepositContract,
        {'from': owner, 'gas': GAS_LIMIT}
    ) 

    transparent_staking.setWithdrawCredential(
        withdrawalCredential,
        {'from': owner, 'gas': GAS_LIMIT}
    )

    transparent_staking.registerValidator(
            0x83fd150d4b851deac570546d1f761632dc76e3df576ec167abfa49de5206ace9f8fc57810007cfe7d317ba604005a14c,
            0xb5f69d8528c028c659042424e859ebacee21f79891bc30801d31d742aae2f360f30f18fd815ef6ba9f39d9af0190652d10d7fa2d6e418414c69389de479adfba5021b2b6503653107f3192dccd5a9fcad6cba065cd32d3e55431fef0c46aecb9,
        {'from': owner, 'gas': GAS_LIMIT}
    )

    transparent_staking.mint({'from':owner, 'value': '1 ether', 'gas': GAS_LIMIT})
    transparent_staking.pushBeacon(1, '1.1 ethers', time.time(), {'from':owner})
    transparent_xeth.approve(transparent_staking, '10000 ethers', {'from': owner})
    transparent_staking.redeemFromValidators('1 ethers', {'from':owner})
    #transparent_staking.validatorStopped([0],{'from':accounts[0],'value':'32.33 ethers'})
    transparent_staking.stoppedBalance()
    transparent_staking.exchangeRatio()



