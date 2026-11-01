import fs from 'node:fs/promises'

export class Example extends plugin {
  constructor() {
    super({
      name: '原版 Node 计数示例',
      event: 'message',
      rule: [{ reg: '^#原包计数$', fnc: 'count' }],
    })
  }

  async count(e) {
    await fs.mkdir('data', { recursive: true })
    const file = 'data/example-count.txt'
    const value = Number(await fs.readFile(file, 'utf8').catch(() => '0')) + 1
    await fs.writeFile(file, String(value))
    await e.reply(`本机器人已调用 ${value} 次`)
    return true
  }
}
