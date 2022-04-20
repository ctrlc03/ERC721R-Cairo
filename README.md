# ERC721R-Cairo

Cairo implementation of ERC721R - an ERC721 refundable implementation. 

Author: @ctrlc03

## Introduction 

ERC721R is a new standard for NFT projects which allows users to refund their NFT within the allocated refund period. This can be used to inspire trust on the project team as investors can get a full refund should the team not work on the project as promised.  

The entirety of the funds are not withdrawable by the project owners within the allocated refund period. This can of course be adapted to fit the needs of the project team where for instance they can access a percentage of the funds to work on the project.

## Contributions

Feel free to fork the project and extend it to fit your needs. It would be interesting to implement a vesting period for the refunded amount. 
Writing tests would also be of great help. 

## References

This was ported from Exo Digital Labs Solidity version available at https://github.com/exo-digital-labs/ERC721R. All credit goes to them, I only ported this to Cairo and applied few changes. 

## Note 

This project is not audited so use at your own risk. 
