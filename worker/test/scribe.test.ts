import assert from "node:assert/strict";
import { test } from "node:test";
import { mayDictate } from "../src/scribe.ts";

test("only the logins allowed may dictate, case aside", () => {
  assert.equal(mayDictate("mariusae", "mariusae"), true);
  assert.equal(mayDictate("MariusAE", " someone, mariusae "), true);
  assert.equal(mayDictate("someone-else", "mariusae"), false);
  assert.equal(mayDictate("mariusae", ""), false);
  assert.equal(mayDictate("mariusae", undefined), false);
  assert.equal(mayDictate("", ","), false);
});
