// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC721WithSupply {
	function totalSupply() external view returns (uint256);
	function ownerOf(uint256 tokenId) external view returns (address);
	function isApprovedForAll(address owner, address operator) external view returns (bool);
}

interface IMarketplace {
	struct Listing {
		uint64 quantity;
		uint128 pricePerItem;
		uint64 expirationTime;
		address paymentToken;
	}
	function listings(address nftAddress, uint256 tokenId, address seller)
		external
		view
		returns (Listing memory);
}

contract HypiosCheapestFinderChunked {
	struct Cheapest {
		bool found;
		uint256 tokenId;
		address seller;
		uint128 pricePerItem;
		address paymentToken;
	}

	// Scan an explicit set of tokenIds (recommended for batching from UI)
	function findCheapestIds(
		address marketplace,
		address hypios,
		address operatorOverride,
		uint256[] calldata tokenIds
	) external view returns (Cheapest memory result) {
		IERC721WithSupply nft = IERC721WithSupply(hypios);
		IMarketplace mkt = IMarketplace(marketplace);

		uint128 best = type(uint128).max;
		address operator = operatorOverride == address(0) ? marketplace : operatorOverride;

		for (uint256 i = 0; i < tokenIds.length; ) {
			uint256 id = tokenIds[i];

			// Skip non-minted tokenIds
			address owner;
			try nft.ownerOf(id) returns (address o) { owner = o; } catch { unchecked { ++i; } continue; }

			// Pull listing; skip approval check unless quantity > 0
			IMarketplace.Listing memory L = mkt.listings(hypios, id, owner);
			if (L.quantity == 0) { unchecked { ++i; } continue; }

			// Optional: expiry
			if (L.expirationTime != 0 && L.expirationTime < block.timestamp) { unchecked { ++i; } continue; }

			// Validate operator approval only for potentially valid listings
			if (!nft.isApprovedForAll(owner, operator)) { unchecked { ++i; } continue; }

			if (L.pricePerItem < best) {
				best = L.pricePerItem;
				result = Cheapest(true, id, owner, L.pricePerItem, L.paymentToken);
			}

			unchecked { ++i; }
		}
	}

	// Scan a numeric range [startId, endExclusive). Works for 0-based or 1-based.
	function findCheapestRange(
		address marketplace,
		address hypios,
		address operatorOverride,
		uint256 startId,
		uint256 endExclusive
	) external view returns (Cheapest memory result) {
		IERC721WithSupply nft = IERC721WithSupply(hypios);
		IMarketplace mkt = IMarketplace(marketplace);

		uint128 best = type(uint128).max;
		address operator = operatorOverride == address(0) ? marketplace : operatorOverride;

		for (uint256 id = startId; id < endExclusive; ) {
			address owner;
			try nft.ownerOf(id) returns (address o) { owner = o; } catch { unchecked { ++id; } continue; }

			IMarketplace.Listing memory L = mkt.listings(hypios, id, owner);
			if (L.quantity == 0) { unchecked { ++id; } continue; }

			if (L.expirationTime != 0 && L.expirationTime < block.timestamp) { unchecked { ++id; } continue; }

			if (!nft.isApprovedForAll(owner, operator)) { unchecked { ++id; } continue; }

			if (L.pricePerItem < best) {
				best = L.pricePerItem;
				result = Cheapest(true, id, owner, L.pricePerItem, L.paymentToken);
			}

			unchecked { ++id; }
		}
	}
}
