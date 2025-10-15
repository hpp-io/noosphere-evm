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
     * @param {number} params.redundancy
     * @param {string} params.walletAddress
     * @param {bigint} params.feeAmount
     * @param {string} params.feeToken
     * @param {string} params.verifier
     * @param {string} params.coordinator
     */
    constructor({
                    requestId,
                    subscriptionId,
                    containerId,
                    interval,
                    useDeliveryInbox,
                    redundancy,
                    walletAddress,
                    feeAmount,
                    feeToken,
                    verifier,
                    coordinator
                }) {
        this.data = {
            requestId,
            subscriptionId,
            containerId,
            interval,
            useDeliveryInbox,
            redundancy,
            walletAddress,
            feeAmount,
            feeToken,
            verifier,
            coordinator
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
            redundancy: commitmentData.redundancy,
            walletAddress: commitmentData.walletAddress,
            feeAmount: commitmentData.feeAmount,
            feeToken: commitmentData.feeToken,
            verifier: commitmentData.verifier,
            coordinator: commitmentData.coordinator,
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
            this.data.redundancy,
            this.data.walletAddress,
            this.data.feeAmount,
            this.data.feeToken,
            this.data.verifier,
            this.data.coordinator,
        ];

        return ethers.AbiCoder.defaultAbiCoder().encode(
            ['(bytes32,uint64,bytes32,uint32,bool,uint16,address,uint256,address,address,address)'],
            [commitmentTuple]
        );
    }
}

module.exports = {Commitment};