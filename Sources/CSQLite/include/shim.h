/* Linux has no SQLite3 Swift module the way Apple platforms do, so the system
   library is surfaced through this shim. On Apple platforms `import SQLite3`
   is used instead and this target is not built at all. */
#include <sqlite3.h>
