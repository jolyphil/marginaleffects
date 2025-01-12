#' Marginal Effects
#'
#' This function calculates marginal effects (slopes) for each row of the
#' dataset. The resulting object can processed by the `tidy()` or `summary()`
#' functions, which compute Average Marginal Effects (AME). The `datagrid()`
#' function and the `newdata` argument can be used to calculate Marginal
#' Effects at the Mean (MEM) or Marginal Effects at User-Specified values (aka
#' Marginal Effects at Representative values, MER). Additional information can
#' be found in the Details and Examples sections below, and in the vignette on
#' the `marginaleffects` website.
#'
#' A "marginal effect" is the partial derivative of the regression equation
#' with respect to a variable in the model. This function uses automatic
#' differentiation to compute marginal effects for a vast array of models,
#' including non-linear models with transformations (e.g., polynomials).
#' Uncertainty estimates are computed using the delta method.
#'
#' A detailed vignette on marginal effects and a list of supported models can
#' be found on the package website:
#'
#' https://vincentarelbundock.github.io/marginaleffects/
#'
#' @param model Model object
#' @param variables Variables to consider (character vector). `NULL`
#'   calculates marginal effects for all terms in the model object.
#' @param vcov Matrix or boolean
#'   + FALSE: does not compute unit-level standard errors. This can speed up computation considerably. 
#'   + TRUE: computes unit-level standard errors using the default `vcov(model)` variance-covariance matrix.
#'   + Named square matrix: computes standard errors with a user-supplied variance-covariance matrix. This matrix must be square and have dimensions equal to the number of coefficients in `get_coef(model)`.
#' @param newdata A dataset over which to compute marginal effects. `NULL` uses
#'   the original data used to fit the model.
#' @param type Type(s) of prediction as string or character vector. This can
#'   differ based on the model type, but will typically be a string such as:
#'   "response", "link", "probs", or "zero".
#' @param ... Additional arguments are passed to the `predict()` method used to
#'   compute adjusted predictions. These arguments are particularly useful for
#'   mixed-effects or bayesian models (see the online vignettes on the
#'   `marginaleffects` website). Available arguments can vary from model to
#'   model, depending on the range of supported arguments by each modeling
#'   package. See the "Model-Specific Arguments" section of the
#'   `?marginaleffects` document for a non-exhaustive list of available
#'   arguments.
#'
#' @template model_specific_arguments
#'
#' @return A `data.frame` with one row per observation (per term/group) and several columns:
#' * `rowid`: row number of the `newdata` data frame
#' * `type`: prediction type, as defined by the `type` argument
#' * `group`: (optional) value of the grouped outcome (e.g., categorical outcome models)
#' * `term`: the variable whose marginal effect is computed
#' * `dydx`: marginal effect of the term on the outcome for a given combination of regressor values
#' * `std.error`: standard errors computed by via the delta method.
#' @examplesIf interactive()
#' @examples
#'
#' mod <- glm(am ~ hp * wt, data = mtcars, family = binomial)
#' mfx <- marginaleffects(mod)
#' head(mfx)
#'
#' # Average Marginal Effect (AME)
#' summary(mfx)
#' tidy(mfx)
#' plot(mfx)
#'
#' # Marginal Effect at the Mean (MEM)
#' marginaleffects(mod, newdata = datagrid())
#'
#' # Marginal Effect at User-Specified Values
#' # Variables not explicitly included in `datagrid()` are held at their means
#' marginaleffects(mod,
#'                 newdata = datagrid(hp = c(100, 110)))
#'
#' # Marginal Effects at User-Specified Values (counterfactual)
#' # Variables not explicitly included in `datagrid()` are held at their
#' # original values, and the whole dataset is duplicated once for each
#' # combination of the values in `datagrid()`
#' mfx <- marginaleffects(mod,
#'                        newdata = datagrid(hp = c(100, 110),
#'                                           grid.type = "counterfactual"))
#' head(mfx)
#'
#' # Heteroskedasticity robust standard errors
#' marginaleffects(mod, vcov = sandwich::vcovHC(mod))
#'
#' @export
marginaleffects <- function(model,
                            newdata = NULL,
                            variables = NULL,
                            vcov = TRUE,
                            type = "response",
                            ...) {


    # order of the first few paragraphs is important
    # if `newdata` is a call to `typical` or `counterfactual`, insert `model`
    scall <- substitute(newdata)
    if (is.call(scall)) {
        lcall <- as.list(scall)
        fun_name <- as.character(scall)[1]
        if (fun_name %in% c("datagrid", "typical", "counterfactual")) {
            if (!any(c("model", "newdata") %in% names(lcall))) {
                lcall <- c(lcall, list("model" = model))
                newdata <- eval.parent(as.call(lcall))
            }
        } else if (fun_name == "visualisation_matrix") {
            if (!"x" %in% names(lcall)) {
                lcall <- c(lcall, list("x" = insight::get_data(model)))
                newdata <- eval.parent(as.call(lcall))
            }
        }
    }

    # modelbased::visualisation_matrix attaches useful info for plotting
    attributes_newdata <- attributes(newdata)
    idx <- c("class", "row.names", "names", "data", "reference")
    idx <- !names(attributes_newdata) %in% idx
    attributes_newdata <- attributes_newdata[idx]

    # sanity checks and pre-processing
    model <- sanity_model(model = model, ...)
    sanity_dots(model = model, ...)
    sanity_type(model = model, type = type, calling_function = "marginaleffects")
    newdata <- sanity_newdata(model, newdata)
    variables <- sanitize_variables(model, newdata, variables)
    vcov <- sanitize_vcov(model, vcov)

    # rowid is required for later merge
    if (!"rowid" %in% colnames(newdata)) {
        newdata$rowid <- 1:nrow(newdata)
    }

    # variables is a list but we need a vector
    variables_vec <- unique(unlist(variables))
    # this won't be triggered for multivariate outcomes in `brms`, which
    # produces a list of lists where top level names correspond to names of the
    # outcomes. There should be a more robust way to handle those, but it seems
    # to work for now.
    if ("conditional" %in% names(variables)) {
        variables_vec <- intersect(variables_vec, variables[["conditional"]])
    }

    mfx_list <- list()

    # compute marginal effects and standard errors
    mfx_list <- list()
    se_mean_list <- list()
    draws_list <- list()
    J_list <- list()
    J_mean_list <- list()
    for (predt in type) {
        for (v in variables_vec) {
            mfx <- get_dydx(model = model,
                            variable = v,
                            newdata = newdata,
                            type = predt,
                            vcov = vcov,
                            internal_call = TRUE, # for group column in comparisons
                            ...)
            mfx$type <- predt

            # bayesian draws
            if (!is.null(attr(mfx, "posterior_draws"))) {
                draws_list <- c(draws_list, list(attr(mfx, "posterior_draws")))
                J <- J_mean <- NULL

            # standard errors via delta method
            } else if (!is.null(vcov)) {
                idx <- intersect(colnames(mfx), c("type", "group", "term", "contrast"))
                idx <- mfx[, idx, drop = FALSE]
                se <- standard_errors_delta(model,
                                            vcov = vcov,
                                            type = predt,
                                            FUN = standard_errors_delta_marginaleffects,
                                            newdata = newdata,
                                            index = idx,
                                            variable = v,
                                            ...)
                mfx$std.error <- as.numeric(se)
                J <- attr(se, "J")
                J_mean <- attr(se, "J_mean")

            # no standard error
            } else {
                J <- J_mean <- NULL
            }

            mfx_list <- c(mfx_list, list(mfx))
            J_list <- c(J_list, list(J))
            J_mean_list <- c(J_mean_list, list(J_mean))
        }
    }

    # could have different columns, so `rbind` won't do
    out <- bind_rows(mfx_list)

    J <- do.call("rbind", J_list) # bind_rows does not work for matrices

    # duplicate colnames can occur for grouped outcome models, so we can't just
    # use `poorman::bind_rows()`. Instead, ugly hack to make colnames unique
    # with a weird string.
    for (i in seq_along(J_mean_list)) {
        if (inherits(J_mean_list[[i]], "data.frame")) {
            newnames <- make.unique(names(J_mean_list[[i]]), sep = "______")
            J_mean_list[[i]] <- stats::setNames(J_mean_list[[i]], newnames)
        }
    }
    J_mean <- bind_rows(J_mean_list) # bind_rows need because some have contrast col
    if (inherits(J_mean, "data.frame")) {
        J_mean <- stats::setNames(J_mean, gsub("______.*$", "", colnames(J_mean)))
    }


    # empty contrasts equal "". important for merging in `tidy()`
    if ("contrast" %in% colnames(J_mean)) {
        J_mean$contrast <- ifelse(is.na(J_mean$contrast), "", J_mean$contrast)
    }

    # standard error at mean gradient (this is what Stata and R's `margins` compute)
    # J_mean is NULL in bayesian models and where the delta method breaks
    if (!is.null(J_mean) && !is.null(vcov)) {
        idx <- !colnames(J_mean) %in% c("type", "group", "term", "contrast")
        tmp <- J_mean[, !idx, drop = FALSE]
        J_mean_mat <- as.matrix(J_mean[, idx, drop = FALSE])
        # converting to data.frame can sometimes break colnames
        colnames(J_mean_mat) <- colnames(J)
        # aggressive check. probably needs to be relaxed.
        if (any(colnames(J_mean_mat) != colnames(vcov))) {
            tmp <- NULL
            warning("The variance covariance matrix and the Jacobian do not match. `marginaleffects` is unable to compute standard errors using the delta method.")
        } else {
            V <- colSums(t(J_mean_mat %*% vcov) * t(J_mean_mat))
            tmp$std.error <- sqrt(V)
        }
        se_at_mean_gradient <- tmp
    } else {
        se_at_mean_gradient <- NULL
    }

    # bayesian posterior draws
    draws <- do.call("rbind", draws_list)
    if (!is.null(draws)) {
        if (!"conf.low" %in% colnames(out)) {
            tmp <- apply(draws, 1, get_hdi)
            out[["std.error"]] <- NULL
            out[["dydx"]] <- apply(draws, 1, stats::median)
            out[["conf.low"]] <- tmp[1, ]
            out[["conf.high"]] <- tmp[2, ]
        }
    }

    # merge newdata if requested and restore attributes
    return_data <- sanitize_return_data()
    if (isTRUE(return_data)) {
        out <- left_join(out, newdata, by = "rowid")
    }

    # clean columns
    stubcols <- c("rowid", "type", "group", "term", "contrast", "dydx", "std.error",
                  sort(grep("^predicted", colnames(newdata), value = TRUE)))
    cols <- intersect(stubcols, colnames(out))
    cols <- unique(c(cols, colnames(out)))
    out <- out[, cols]

    if ("group" %in% colnames(out) && all(out$group == "main_marginaleffect")) {
        out$group <- NULL
    }

    # return contrast column only when relevant
    if ("contrast" %in% colnames(out)) {
        if (all(is.na(out$contrast))) {
            out$contrast <- NULL
        } else {
            out$contrast[is.na(out$contrast)] <- ""
        }
    }

    # DO NOT sort rows because we want draws to match
    row.names(out) <- NULL

    # we want consistent output, regardless of whether `data.table` is installed/used or not
    out <- as.data.frame(out)

    class(out) <- c("marginaleffects", class(out))
    attr(out, "posterior_draws") <- draws
    attr(out, "model") <- model
    attr(out, "type") <- type
    attr(out, "model_type") <- class(model)[1]
    attr(out, "variables") <- variables
    attr(out, "J") <- J
    attr(out, "J_mean") <- J_mean
    attr(out, "se_at_mean_gradient") <- se_at_mean_gradient

    # modelbased::visualisation_matrix attaches useful info for plotting
    for (a in names(attributes_newdata)) {
        attr(out, paste0("newdata_", a)) <- attributes_newdata[[a]]
    }

    return(out)
}


#' `meffects()` is a shortcut to `marginaleffects()`
#'
#' @inherit marginaleffects
#' @keywords internal
#' @export
meffects <- marginaleffects
