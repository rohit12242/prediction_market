#!/usr/bin/env node
/**
 * update-addresses.js
 *
 * Reads ../contracts/deployments/<network>.json and patches the correct
 * subgraph YAML file with real contract addresses.
 *
 * Usage:
 *   node scripts/update-addresses.js localhost     # updates subgraph.local.yaml
 *   node scripts/update-addresses.js matic         # updates subgraph.yaml
 *   node scripts/update-addresses.js mumbai        # updates subgraph.yaml
 *
 * Prerequisites:
 *   Run `make deploy-<network>` from packages/contracts first so that
 *   deployments/<network>.json exists with the deployed addresses.
 *
 * Expected deployments/<network>.json shape:
 *   {
 *     "MarketFactory":    "0x...",
 *     "PredictionMarket": "0x...",
 *     "FPMMFactory":      "0x...",
 *     "UMAOracleAdapter": "0x..."
 *   }
 */

'use strict'

const fs   = require('fs')
const path = require('path')

const network  = process.argv[2] || 'localhost'
const yamlFile = network === 'localhost' ? 'subgraph.local.yaml' : 'subgraph.yaml'

const deploymentsFile = path.join(
  __dirname,
  '../../contracts/deployments',
  `${network}.json`
)

if (!fs.existsSync(deploymentsFile)) {
  console.error(`\nERROR: No deployments file found at: ${deploymentsFile}`)
  console.error(`Run 'make deploy-${network}' from packages/contracts first.\n`)
  process.exit(1)
}

let deployments
try {
  deployments = JSON.parse(fs.readFileSync(deploymentsFile, 'utf8'))
} catch (err) {
  console.error(`\nERROR: Failed to parse ${deploymentsFile}: ${err.message}\n`)
  process.exit(1)
}

const yamlPath = path.join(__dirname, '..', yamlFile)
if (!fs.existsSync(yamlPath)) {
  console.error(`\nERROR: YAML file not found: ${yamlPath}\n`)
  process.exit(1)
}

let yaml = fs.readFileSync(yamlPath, 'utf8')

/**
 * Contract name → deployment key mapping.
 * Each entry: [yamlName, deploymentsKey]
 */
const CONTRACT_MAP = [
  ['MarketFactory',    'MarketFactory'],
  ['PredictionMarket', 'PredictionMarket'],
  ['FPMMFactory',      'FPMMFactory'],
  ['UMAOracleAdapter', 'UMAOracleAdapter'],
]

const updated = {}
const skipped = []

for (const [yamlName, deployKey] of CONTRACT_MAP) {
  const address = deployments[deployKey]
  if (!address) {
    skipped.push(`${yamlName} (key "${deployKey}" not found in deployments file)`)
    continue
  }

  // Match the address field that follows a `name: <yamlName>` stanza.
  // The regex handles any amount of whitespace between the name line and the
  // address line, even across intermediate lines (e.g. network:).
  const regex = new RegExp(
    `(name:\\s+${yamlName}[\\s\\S]*?address:\\s+)"[^"]*"`,
    'g'
  )

  const before = yaml
  yaml = yaml.replace(regex, `$1"${address}"`)

  if (yaml !== before) {
    updated[yamlName] = address
  } else {
    skipped.push(`${yamlName} (pattern not matched in YAML — check datasource name)`)
  }
}

fs.writeFileSync(yamlPath, yaml, 'utf8')

console.log(`\nUpdated ${yamlFile} with addresses from ${network} deployment:\n`)
for (const [name, addr] of Object.entries(updated)) {
  console.log(`  ✓  ${name.padEnd(20)} ${addr}`)
}
if (skipped.length > 0) {
  console.log('\nSkipped (no change):')
  for (const msg of skipped) {
    console.log(`  -  ${msg}`)
  }
}
console.log()
