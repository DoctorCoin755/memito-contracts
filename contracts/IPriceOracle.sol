// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title Prices for everything the city holds
/// @notice The treasury never guesses what money is worth. It asks this one
///         place, and this one place is fixed at birth and cannot be swapped.
interface IPriceOracle {
    /// @notice Dollar value of an amount of an asset, always with 18 decimals.
    /// @param asset ERC-20 address, or address(0) for native ETH.
    /// @param amount raw amount in the asset's own decimals.
    /// @return usd value in dollars, 18 decimals. Reverts if the price is
    ///         unknown or too old to trust — silence is safer than a wrong number.
    function usdValue(address asset, uint256 amount) external view returns (uint256 usd);

    /// @notice How much of an asset makes up a given dollar amount.
    /// @dev The mirror of usdValue, used when a player names the sum in dollars
    ///      and the contract has to hand over coins.
    function assetAmount(address asset, uint256 usd) external view returns (uint256 amount);

    /// @notice True if this oracle can price the asset at all.
    /// @dev Named supportsAsset, not supports: `supports` is a reserved word in
    ///      Solidity 0.8.24 and will not compile as an identifier.
    function supportsAsset(address asset) external view returns (bool);

    /// @notice May the treasury count this asset as backing, and hand it out?
    /// @dev False the moment the asset cannot be priced. Late and gone are the
    ///      same answer on purpose: any gap between "no longer priceable" and
    ///      "written off" is a stretch in which a holding is neither, and a
    ///      treasury that sums its holdings all or nothing stops paying in
    ///      EVERY coin for the length of that stretch. One threshold, no gap.
    ///
    ///      Implementations must answer false for a coin the game itself
    ///      prices. A bank may not value itself by a number its own customers
    ///      can move, and a price that lives only while somebody keeps poking
    ///      it is a keeper the owner would have to be — see
    ///      MemitoPriceOracle.marketAlive.
    function marketAlive(address asset) external view returns (bool);
}
