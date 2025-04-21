// Import and register all your controllers from the controllers directory.
// The new commands will automatically load controllers as required.

import { application } from "./application"

// Eager load all controllers defined in the import map under controllers/**/*_controller
import { eagerLoadControllersFrom } from "@hotwired/stimulus-loading"
eagerLoadControllersFrom("controllers", application) 