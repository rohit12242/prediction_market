import { GraphQLScalarType, Kind } from 'graphql'
import { marketResolvers } from './market.js'
import { authResolvers } from './auth.js'

const DateTimeScalar = new GraphQLScalarType({
  name: 'DateTime',
  description: 'ISO-8601 date-time string',
  serialize(value) {
    if (value instanceof Date) return value.toISOString()
    if (typeof value === 'string' || typeof value === 'number') return new Date(value).toISOString()
    throw new Error(`DateTime cannot serialize value: ${value}`)
  },
  parseValue(value) {
    if (typeof value === 'string') return new Date(value)
    throw new Error('DateTime must be a string')
  },
  parseLiteral(ast) {
    if (ast.kind === Kind.STRING) return new Date(ast.value)
    throw new Error('DateTime literal must be a string')
  },
})

const BigIntScalar = new GraphQLScalarType({
  name: 'BigInt',
  description: 'Large integer (returned as string to avoid JS precision loss)',
  serialize(value) {
    return String(value)
  },
  parseValue(value) {
    return BigInt(value as string)
  },
  parseLiteral(ast) {
    if (ast.kind === Kind.INT || ast.kind === Kind.STRING) return BigInt(ast.value)
    throw new Error('BigInt literal must be an integer or string')
  },
})

export const resolvers = {
  DateTime: DateTimeScalar,
  BigInt: BigIntScalar,
  Query: {
    ...marketResolvers.Query,
  },
  Mutation: {
    ...authResolvers.Mutation,
  },
  Market: marketResolvers.Market,
  User: marketResolvers.User,
}
