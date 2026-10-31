/**
 * 极简 Markdown 分块解析：只做手机端需要的几类块。
 * 行内样式（**加粗**、`代码`）在 v1 里退化为纯文本，块级结构完整保留。
 */

export interface MdBlock {
  /** paragraph | heading | code | table | list | quote */
  kind: string
  level: number
  text: string
  lang: string
  rows: string[][]
}

function stripInline(text: string): string {
  return text
    .replace(/\*\*([^*]+)\*\*/g, '$1')
    .replace(/`([^`]+)`/g, '$1')
    .replace(/\[([^\]]+)\]\([^)]*\)/g, '$1')
    .replace(/^\s*>\s?/, '')
}

function isTableSeparator(line: string): boolean {
  return /^\s*\|?[\s:|-]+\|[\s:|-]*$/.test(line) && line.includes('-')
}

function splitRow(line: string): string[] {
  let text = line.trim()
  if (text.startsWith('|')) {
    text = text.slice(1)
  }
  if (text.endsWith('|')) {
    text = text.slice(0, text.length - 1)
  }
  return text.split('|').map((cell: string) => stripInline(cell.trim()))
}

export function parseMarkdown(source: string): MdBlock[] {
  const blocks: MdBlock[] = []
  const lines: string[] = source.replace(/\r\n/g, '\n').split('\n')
  let i = 0

  while (i < lines.length) {
    const line = lines[i]

    if (line.trim() === '') {
      i++
      continue
    }

    // 代码块
    if (line.trim().startsWith('```')) {
      const lang = line.trim().slice(3).trim()
      const body: string[] = []
      i++
      while (i < lines.length && !lines[i].trim().startsWith('```')) {
        body.push(lines[i])
        i++
      }
      i++
      const block: MdBlock = { kind: 'code', level: 0, text: body.join('\n'), lang: lang, rows: [] }
      blocks.push(block)
      continue
    }

    // 表格：当前行含 |，下一行是分隔行
    if (line.includes('|') && i + 1 < lines.length && isTableSeparator(lines[i + 1])) {
      const rows: string[][] = [splitRow(line)]
      i += 2
      while (i < lines.length && lines[i].includes('|') && lines[i].trim() !== '') {
        rows.push(splitRow(lines[i]))
        i++
      }
      const block: MdBlock = { kind: 'table', level: 0, text: '', lang: '', rows: rows }
      blocks.push(block)
      continue
    }

    // 标题
    const heading = /^(#{1,6})\s+(.*)$/.exec(line)
    if (heading !== null) {
      const block: MdBlock = {
        kind: 'heading', level: heading[1].length, text: stripInline(heading[2]), lang: '', rows: []
      }
      blocks.push(block)
      i++
      continue
    }

    // 引用
    if (/^\s*>/.test(line)) {
      const body: string[] = []
      while (i < lines.length && /^\s*>/.test(lines[i])) {
        body.push(stripInline(lines[i]))
        i++
      }
      const block: MdBlock = { kind: 'quote', level: 0, text: body.join('\n'), lang: '', rows: [] }
      blocks.push(block)
      continue
    }

    // 列表
    if (/^\s*([-*+]|\d+\.)\s+/.test(line)) {
      const items: string[] = []
      while (i < lines.length && /^\s*([-*+]|\d+\.)\s+/.test(lines[i])) {
        const content = lines[i].replace(/^\s*([-*+]|\d+\.)\s+/, '')
        items.push('• ' + stripInline(content))
        i++
      }
      const block: MdBlock = { kind: 'list', level: 0, text: items.join('\n'), lang: '', rows: [] }
      blocks.push(block)
      continue
    }

    // 普通段落
    const body: string[] = []
    while (i < lines.length && lines[i].trim() !== ''
      && !lines[i].trim().startsWith('```')
      && !/^(#{1,6})\s+/.test(lines[i])
      && !/^\s*>/.test(lines[i])
      && !/^\s*([-*+]|\d+\.)\s+/.test(lines[i])) {
      body.push(stripInline(lines[i]))
      i++
    }
    const block: MdBlock = { kind: 'paragraph', level: 0, text: body.join('\n'), lang: '', rows: [] }
    blocks.push(block)
  }

  return blocks
}
