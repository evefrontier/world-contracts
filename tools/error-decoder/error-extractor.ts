import * as fs from 'node:fs'
import * as path from 'node:path'

interface ErrorDefinition {
  moduleName: string
  errorCode: number
  constantName: string
  errorMessage: string
}

/**
 * Extracts error definitions from Move source files
 */
function extractErrorsFromMoveFile(filePath: string): ErrorDefinition[] {
  let content: string
  try {
    content = fs.readFileSync(filePath, 'utf-8')
  } catch (error) {
    console.error(`Error reading file ${filePath}:`, error)
    return []
  }
  const errors: ErrorDefinition[] = []

  // Extract module name (any package namespace, e.g. core::entity, character::identity)
  const moduleMatch = content.match(/module\s+\w+::(\w+)\s*;/)
  if (!moduleMatch) {
    return errors
  }
  const moduleName = moduleMatch[1]

  const errorRegex =
    /#\[error\(code\s*=\s*(\d+)\)\]\s*const\s+([A-Z][A-Za-z0-9_]+)\s*:\s*vector<u8>\s*=\s*b"([^"]+)"/gs

  let match = errorRegex.exec(content)
  while (match !== null) {
    const errorCode = parseInt(match[1], 10)
    const constantName = match[2]
    const errorMessage = match[3]

    errors.push({
      moduleName,
      errorCode,
      constantName,
      errorMessage,
    })
    match = errorRegex.exec(content)
  }

  return errors
}

/**
 * Recursively finds all .move files in a directory
 */
function findMoveFiles(dir: string): string[] {
  const files: string[] = []

  function walkDir(currentDir: string) {
    const entries = fs.readdirSync(currentDir, { withFileTypes: true })

    for (const entry of entries) {
      const fullPath = path.join(currentDir, entry.name)

      if (entry.isDirectory()) {
        // Skip build directories and dependencies
        if (
          entry.name !== 'build' &&
          entry.name !== 'dependencies' &&
          entry.name !== 'node_modules'
        ) {
          walkDir(fullPath)
        }
      } else if (entry.isFile() && entry.name.endsWith('.move')) {
        files.push(fullPath)
      }
    }
  }

  walkDir(dir)
  return files
}

/**
 * Returns every existing package `sources/` dir under contracts/ except archive
 * TODO: remove it when archive folder is removed
 */
function findPackageDirs(contractsDir: string): string[] {
  return fs
    .readdirSync(contractsDir, { withFileTypes: true })
    .filter((e) => e.isDirectory() && e.name !== 'archive')
    .map((e) => path.join(contractsDir, e.name, 'sources'))
    .filter((dir) => fs.existsSync(dir))
}

function generateErrorMap(outputPath: string, contractsDir: string) {
  const moveFiles = findPackageDirs(contractsDir).flatMap(findMoveFiles)
  const allErrors: ErrorDefinition[] = []

  for (const file of moveFiles) {
    const errors = extractErrorsFromMoveFile(file)
    allErrors.push(...errors)
  }

  // Group by module name
  // Structure: module -> errorCode -> { constantName, errorMessage }
  const errorMap: Record<
    string,
    Record<number, { constantName: string; errorMessage: string }>
  > = {}

  for (const error of allErrors) {
    if (!errorMap[error.moduleName]) {
      errorMap[error.moduleName] = {}
    }
    errorMap[error.moduleName][error.errorCode] = {
      constantName: error.constantName,
      errorMessage: error.errorMessage,
    }
  }

  fs.writeFileSync(
    outputPath,
    `${JSON.stringify(errorMap, null, 2)}\n`,
    'utf-8',
  )
  console.log(
    `Generated error map with ${allErrors.length} error definitions from ${moveFiles.length} Move files`,
  )
  console.log(`Modules found: ${Object.keys(errorMap).join(', ')}`)
}

// Main execution
// Get the directory of this script file
// Use process.cwd() as base and resolve relative to project root
const projectRoot = process.cwd()
const contractsDir = path.join(projectRoot, 'contracts')
const outputPath = path.join(projectRoot, 'tools/error-decoder/error-map.json')

if (!fs.existsSync(contractsDir)) {
  console.error(`Error: Contracts directory not found at ${contractsDir}`)
  process.exit(1)
}

generateErrorMap(outputPath, contractsDir)
