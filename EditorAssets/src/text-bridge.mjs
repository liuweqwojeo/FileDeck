import { lineEndingField } from "./line-endings.mjs";

// 协议位置使用原始正文的 UTF-16 偏移，与 JS 字符串和 Foundation NSRange 一致。
// 只缓存本会话最近一次行尾映射，避免每份撤销快照各持有一个整文档前缀数组。
export function createTextEditEncoder() {
  let cachedEndings = null, extra = [];
  return (update) => {
    const before = update.startState.field(lineEndingField).endings;
    const after = update.state.field(lineEndingField).endings;
    if (cachedEndings !== before) {
      extra = [0];
      for (const ending of before) extra.push(extra.at(-1) + (ending === "\r\n" ? 1 : 0));
      cachedEndings = before;
    }
    const edits = [];
    let oldCursor = 0, newCursor = 0, consistent = true;
    const unchanged = (oldEnd, newEnd) => {
      if (before === after && oldCursor === newCursor && oldEnd === newEnd) {
        oldCursor = oldEnd; newCursor = newEnd; return;
      }
      if (oldEnd - oldCursor !== newEnd - newCursor) consistent = false;
      while (oldCursor < oldEnd) {
        if (before[oldCursor++] !== after[newCursor++]) consistent = false;
      }
    };
    update.changes.iterChanges((from, to, newFrom, newTo, inserted) => {
      const first = update.startState.doc.lineAt(from).number - 1;
      const last = update.startState.doc.lineAt(to).number - 1;
      const newFirst = update.state.doc.lineAt(newFrom).number - 1;
      const newLast = update.state.doc.lineAt(newTo).number - 1;
      unchanged(first, newFirst);
      let ending = newFirst;
      edits.push({ from: from + extra[first], to: to + extra[last],
        text: inserted.toString().replace(/\n/g, () => after[ending++]) });
      oldCursor = last; newCursor = newLast;
    });
    unchanged(before.length, after.length);
    // 恢复 effect 若还改了编辑区外的换行，必须回退到完整快照，不能发送遗漏原始字节的差量。
    return consistent ? edits : null;
  };
}
