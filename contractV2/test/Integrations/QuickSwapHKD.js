// TRUFFLE

const PancakeFactory = artifacts.require('IPancakeFactory')
const PancakeRouter = artifacts.require('IPancakeRouter01')
const PancakePair = artifacts.require('IPancakePair')
const MockToken = artifacts.require('MockToken')
const TokenManager = artifacts.require('TokenManager')
const TokenFactory = artifacts.require('TokenFactory')
const ChainlinkPriceFeeder = artifacts.require('ChainlinkPriceFeeder')
const PriceResolver = artifacts.require('PriceResolver')
const SyntheticToken = artifacts.require('SyntheticToken')

const { expect } = require("chai");
const { ethers } = require("ethers");
const { fromEther, toEther } = require("../Helpers")

let router
let factory 
let pair
let tokenFactory
let baseCollateral
let supportCollateral
let chainlinkPriceFeeder
let chainlinkPriceFeederCollateral
let priceResolver
let tokenManager
let syntheticToken

contract("QuickSwap HKD", (accounts) => {

    const admin = accounts[0]
    const alice = accounts[1]
    const bob = accounts[2]
    const dev = accounts[3]

    const FACTORY_ADDRESS = "0x5757371414417b8C6CAad45bAeF941aBc7d3Ab32"
    const ROUTER_ADDRESS = "0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff"

    let isPolygon = false

    before(async () => {

        try {

            tokenFactory = await TokenFactory.new()

            // setup collateral tokens
            baseCollateral = await MockToken.new("Tamago Token", "TAMG")
            supportCollateral = await MockToken.new("USDC", "USDC")

            // setup price feeders
            chainlinkPriceFeeder = await ChainlinkPriceFeeder.new(
                "HKD",
                "0x82d43B72573f902F960126a19581BcBbA5b014F5",
                8
            )

            chainlinkPriceFeederCollateral = await ChainlinkPriceFeeder.new(
                "MATIC",
                "0x7bAC85A8a13A4BcD8abb3eB7d6b4d632c5a57676",
                8
            )

            priceResolver = await PriceResolver.new(
                chainlinkPriceFeeder.address,
                chainlinkPriceFeederCollateral.address,
                toEther(400),
                admin
            )

            // setup a minter contract
            tokenManager = await TokenManager.new(
                "Synthetic HKD",
                "sHKD",
                tokenFactory.address,
                priceResolver.address,
                baseCollateral.address,
                supportCollateral.address,
                admin
            )

            const syntheticTokenAddress = await tokenManager.syntheticToken()
            syntheticToken = await SyntheticToken.at(syntheticTokenAddress)

            // setup QuickSwap pool
            router = await PancakeRouter.at(ROUTER_ADDRESS)
            factory = await PancakeFactory.at(FACTORY_ADDRESS)

            // should be failed if doesn't run on forked polygon
            const factoryAddress = await router.factory()

            if (factoryAddress === FACTORY_ADDRESS) {
                isPolygon = true
            }

        } catch (e) {
            console.log(e)
        }

    })

    it('deploy a USDC/TAMG contract ', async () => {

        if (isPolygon) {
            const tx = await factory.createPair(supportCollateral.address, baseCollateral.address)
            const pairAddress = tx['logs'][0]['args']['pair']
            pair = await PancakePair.at(pairAddress)

            expect(await pair.factory()).to.equal(FACTORY_ADDRESS)
        }

    })

    it('mint HKD tokens equivalent of $1000', async () => {

        if (isPolygon) {

            await supportCollateral.transfer(pair.address, toEther(1000)) // 1000 USDC
            await baseCollateral.transfer(pair.address, toEther(7800)) // 7800 HKD = 1000 USDC x 7.8 HKD / USD
            await pair.mint(admin)

            // const output = await pair.getReserves()

            expect(  fromEther((await pair.balanceOf(admin)).toString()) ).to.equal("2792.848008753788232976")
        }

    })

    it('swap token A -> token B', async () => {

        if (isPolygon) {

            const baseTokenIn = 10

            const pairTokenOut = await router.getAmountsOut( toEther(baseTokenIn) , [supportCollateral.address, baseCollateral.address] )

            await supportCollateral.transfer(bob , toEther(1000))

            expect( fromEther(pairTokenOut[1].toString()) ).to.equal("76.99832668297078131")

            await supportCollateral.approve(router.address, ethers.constants.MaxUint256, { from : bob })
            await router.swapTokensForExactTokens( pairTokenOut[1], toEther(baseTokenIn),  [supportCollateral.address, baseCollateral.address], bob, 999999999999999 , { from : bob} )
            
            expect( fromEther( (await baseCollateral.balanceOf( bob)).toString() )).to.equal("76.99832668297078131")
        }

    })

})