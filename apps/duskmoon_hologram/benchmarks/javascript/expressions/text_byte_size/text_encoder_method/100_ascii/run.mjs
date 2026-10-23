"use strict";

import {benchmark} from "../../../../support/helpers.mjs";

const text =
  "abcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghij";

const encoder = new TextEncoder("utf-8");

benchmark(() => {
  return encoder.encode(text).length;
});
