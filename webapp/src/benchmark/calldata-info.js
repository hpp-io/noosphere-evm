// utils/calldata-info.js
const ethers = require('ethers');

/**
 * contractInterface: contract.interface (ethers.Interface)
 * functionName: string e.g. 'reportComputeResult'
 * args: array of function args (in JS forms acceptable to Interface)
 *
 * returns {
 *   calldataHex,
 *   calldataBytes,
 *   zeroBytes,
 *   nonZeroBytes,
 *   calldataGasEstimate  // zero*4 + nonzero*16
 * }
 */
function computeCalldataInfo(contractInterface, functionName, args) {
    // encodeFunctionData will produce the full calldata hex
    const calldataHex = contractInterface.encodeFunctionData(functionName, args);
    const calldataBytes = Math.max(0, (calldataHex.length - 2) / 2);

    // Count zero / non-zero bytes
    const buf = Buffer.from(calldataHex.slice(2), 'hex');
    let zeroBytes = 0;
    for (let i = 0; i < buf.length; i++) if (buf[i] === 0) zeroBytes++;
    const nonZeroBytes = buf.length - zeroBytes;

    // Per-byte calldata gas
    const calldataGasEstimate = zeroBytes * 4 + nonZeroBytes * 16;

    return {
        calldataHex,
        calldataBytes,
        zeroBytes,
        nonZeroBytes,
        calldataGasEstimate
    };
}

module.exports = { computeCalldataInfo };
