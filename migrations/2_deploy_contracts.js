// var MyContract = artifacts.require("./MyContract.sol");

module.exports = function(deployer) {
  // deployer.deploy(MyContract);
};

var ArbRewarder = artifacts.require("./ArbRewarder.sol");


module.exports = function(deployer) {

try {

  deployer.deploy(ArbRewarder, 'TXmCmvHdZL8SRwtvBjU4jJDTeTKoq14tkA').then(function() {
    
 });


}  catch (err) {
 console.log("error while deploying", err);	
}  
 
};
