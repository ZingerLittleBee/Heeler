/** Complete JSONL records with byte offsets; unfinished UTF-8 tails are retried. */
export async function* jsonLines(input, start = 0, skip = 0, onChunk = () => {}) {
  let fragments = [];
  let length = 0;
  let offset = start;
  for await (let chunk of input) {
    onChunk();
    if (skip >= chunk.length) { skip -= chunk.length; continue; }
    if (skip) { chunk = chunk.subarray(skip); skip = 0; }
    let from = 0;
    let newline;
    while ((newline = chunk.indexOf(10, from)) >= 0) {
      const part = chunk.subarray(from, newline);
      fragments.push(part);
      length += part.length;
      offset += length + 1;
      let line = null;
      try { line = JSON.parse(Buffer.concat(fragments, length).toString("utf8")); }
      catch { /* A complete torn line is consumed; a partial tail is not. */ }
      yield { line, offset };
      fragments = [];
      length = 0;
      from = newline + 1;
    }
    if (from < chunk.length) {
      fragments.push(chunk.subarray(from));
      length += chunk.length - from;
    }
  }
}
