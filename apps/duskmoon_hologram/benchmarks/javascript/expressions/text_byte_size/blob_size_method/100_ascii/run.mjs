"use strict";

import {benchmark} from "../../../../support/helpers.mjs";

const text =
  "abcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghij";

benchmark(() => {
  return new Blob([text]).size;
});
