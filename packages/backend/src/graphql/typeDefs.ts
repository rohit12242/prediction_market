export const typeDefs = /* GraphQL */ `
  scalar BigInt
  scalar DateTime

  enum Outcome {
    UNRESOLVED
    YES
    NO
    INVALID
  }

  type Market {
    id: ID!
    creator: String!
    question: String!
    description: String!
    endTime: DateTime!
    resolutionTime: DateTime!
    outcome: Outcome!
    yesPrice: Float!
    noPrice: Float!
    totalLiquidity: String!
    resolved: Boolean!
    createdAt: DateTime!
    trades(limit: Int, offset: Int): [Trade!]!
  }

  type Trade {
    id: ID!
    marketId: ID!
    trader: String!
    isYes: Boolean!
    amountIn: String!
    sharesOut: String!
    txHash: String!
    timestamp: DateTime!
  }

  type Position {
    id: ID!
    marketId: ID!
    trader: String!
    yesShares: String!
    noShares: String!
    totalInvested: String!
    realizedPnl: String!
  }

  type User {
    address: String!
    positions: [Position!]!
    trades(limit: Int, offset: Int): [Trade!]!
  }

  type Query {
    markets(
      limit: Int
      offset: Int
      resolved: Boolean
      search: String
    ): [Market!]!
    market(id: ID!): Market
    positions(trader: String!): [Position!]!
    trades(marketId: ID, trader: String, limit: Int, offset: Int): [Trade!]!
    me: User
  }

  type Mutation {
    nonce(address: String!): String!
    login(address: String!, signature: String!): AuthPayload!
  }

  type Subscription {
    marketUpdated(id: ID!): Market!
    newTrade(marketId: ID!): Trade!
  }

  type AuthPayload {
    token: String!
    address: String!
  }
`
