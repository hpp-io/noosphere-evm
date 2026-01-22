const ethers = require('ethers');

/**
 * Represents a Commitment structure and provides utility methods for encoding.
 */
class Commitment {
    /**
     * @param {object} params
     * @param {string} params.requestId
     * @param {bigint} params.subscriptionId
     * @param {string} params.containerId
     * @param {number} params.interval
     * @param {boolean} params.useDeliveryInbox
     * @param {string} params.walletAddress
     * @param {bigint} params.feeAmount
     * @param {string} params.feeToken
     * @param {string} params.verifier
     * @param {string} params.coordinator
     * @param {bigint} params.verifierFee
     */
    constructor({
                    requestId,
                    subscriptionId,
                    containerId,
                    interval,
                    useDeliveryInbox,
                    walletAddress,
                    feeAmount,
                    feeToken,
                    verifier,
                    coordinator,
                    verifierFee
                }) {
        this.data = {
            requestId,
            subscriptionId,
            containerId,
            interval,
            useDeliveryInbox,
            walletAddress,
            feeAmount,
            feeToken,
            verifier,
            coordinator,
            verifierFee
        };
    }

    /**
     * Creates a Commitment instance from an ethers.js event object.
     * @param {ethers.EventLog} event - The event log containing commitment data.
     * @returns {Commitment} A new Commitment instance.
     */
    static fromEvent(event) {
        const commitmentData = event.args.commitment;
        return new Commitment({
            requestId: commitmentData.requestId,
            subscriptionId: commitmentData.subscriptionId,
            containerId: commitmentData.containerId,
            interval: commitmentData.interval,
            useDeliveryInbox: commitmentData.useDeliveryInbox,
            walletAddress: commitmentData.walletAddress,
            feeAmount: commitmentData.feeAmount,
            feeToken: commitmentData.feeToken,
            verifier: commitmentData.verifier,
            coordinator: commitmentData.coordinator,
            verifierFee: commitmentData.verifierFee,
        });
    }

    /**
     * ABI-encodes the commitment data into a hex string.
     * @returns {string} The ABI-encoded commitment data.
     */
    encode() {
        const commitmentTuple = [
            this.data.requestId,
            this.data.subscriptionId,
            this.data.containerId,
            this.data.interval,
            this.data.useDeliveryInbox,
            this.data.walletAddress,
            this.data.feeAmount,
            this.data.feeToken,
            this.data.verifier,
            this.data.coordinator,
            this.data.verifierFee,
        ];

        return ethers.AbiCoder.defaultAbiCoder().encode(
            ['(bytes32,uint64,bytes32,uint32,bool,address,uint256,address,address,address,uint256)'],
            [commitmentTuple]
        );
    }
}

module.exports = {Commitment};
