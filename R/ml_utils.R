#' Prepare a Spark DataFrame for Spark ML Routines
#'
#' This routine prepares a Spark DataFrame for use by Spark ML routines.
#'
#' Spark DataFrames are prepared through the following transformations:
#'
#' \enumerate{
#'   \item All specified columns are transformed into a numeric data type
#'         (using a simple cast for integer / logical columns, and
#'         \code{\link{ft_string_indexer}} for strings),
#'   \item The \code{\link{ft_vector_assembler}} is used to combine the
#'         specified features into a single 'feature' vector, suitable
#'         for use with Spark ML routines.
#' }
#'
#' After calling this function, the \code{envir} environment (when supplied)
#' will be populated with a set of variables:
#'
#' \tabular{ll}{
#' \code{features}:\tab The name of the generated \code{features} vector.\cr
#' \code{response}:\tab The name of the generated \code{response} vector.\cr
#' \code{labels}:  \tab When the \code{response} column is a string vector,
#'                      the \code{\link{ft_string_indexer}} is used to transform
#'                      the vector into a [0:n) numeric vector. The ordered
#'                      labels are injected here to allow for easier mapping
#'                      from the [0:n) values back to the original label.
#' }
#'
#' @template roxlate-ml-x
#' @template roxlate-ml-features
#' @template roxlate-ml-response
#' @template roxlate-ml-dots
#' @template roxlate-ml-options
#' @param envir An \R environment -- when supplied, it will be filled
#'   with metadata describing the transformations that have taken place.
#'
#' @export
#' @examples
#' \dontrun{
#' # example of how 'ml_prepare_dataframe' might be used to invoke
#' # Spark's LinearRegression routine from the 'ml' package
#' envir <- new.env(parent = emptyenv())
#' tdf <- ml_prepare_dataframe(df, features, response, envir = envir)
#'
#' lr <- invoke_new(
#'   sc,
#'   "org.apache.spark.ml.regression.LinearRegression"
#' )
#'
#' # use generated 'features', 'response' vector names in model fit
#' model <- lr %>%
#'   invoke("setFeaturesCol", envir$features) %>%
#'   invoke("setLabelCol", envir$response)
#' }
ml_prepare_dataframe <- function(x,
                                 features,
                                 response = NULL,
                                 ...,
                                 ml.options = ml_options(),
                                 envir = new.env(parent = emptyenv()))
{
  df <- spark_dataframe(x)
  schema <- sdf_schema(df)

  # default report for feature, response variable names
  envir$features <- ml.options$features.column
  envir$response <- response
  envir$labels <- NULL

  # ensure numeric response
  if (!is.null(response)) {
    responseType <- schema[[response]]$type
    if (responseType == "StringType") {
      envir$response <- ml.options$response.column
      df <- ft_string_indexer(df, response, envir$response, envir)
    } else if (responseType != "DoubleType") {
      envir$response <- ml.options$response.column
      castedColumn <- df %>%
        invoke("col", response) %>%
        invoke("cast", "double")
      df <- df %>%
        invoke("withColumn", envir$response, castedColumn)
    }
  }

  # assemble features vector
  transformed <- ft_vector_assembler(df, features, envir$features)

  # return as vanilla spark dataframe
  spark_dataframe(transformed)
}

apply_na_action <- function(x, response = NULL, features = NULL, na.action) {

  # early exit for NULL, NA na.action
  if (is.null(na.action))
    return(x)

  # attempt to resolve character na.action
  if (is.character(na.action)) {
    if (!exists(na.action, envir = parent.frame(), mode = "function"))
      stop("no function with name '", na.action, "' found")

    na.action <- get(na.action, envir = parent.frame(), mode = "function")
  }

  if (!is.function(na.action))
    stop("'na.action' is not a function")

  # attempt to apply 'na.action'
  na.action(x,
            response = response,
            features = features,
            columns = c(response, features))
}

try_null <- function(expr) {
  tryCatch(expr, error = function(e) NULL)
}

#' @export
predict.ml_model <- function(object,
                             newdata = object$data,
                             ...)
{
  # 'sdf_predict()' does not necessarily return a data set with the same row
  # order as the input data; generate a unique id and re-join the generated
  # spark dataframe to ensure the row order is maintained
  id <- random_string("id_")
  sdf <- newdata %>%
    sdf_with_unique_id(id) %>%
    spark_dataframe()

  # perform prediction
  params <- object$model.parameters
  predicted <- sdf_predict(object, sdf, ...)

  # join prediction column on original data, then read prediction column
  column <- sdf %>%
    invoke("join", spark_dataframe(predicted), as.list(id)) %>%
    sdf_read_column("prediction")

  # re-order based on id
  if (is.character(params$labels) && is.numeric(column))
    column <- params$labels[column + 1]

  column
}

#' @export
fitted.ml_model <- function(object, ...) {

  predictions <- object$.model %>%
    invoke("summary") %>%
    invoke("predictions")

  id <- object$model.parameters$id
  object$data %>%
    invoke("join", predictions, as.list(id)) %>%
    sdf_read_column("prediction")
}

#' @export
residuals.ml_model <- function(object, ...) {
  object$.model %>%
    invoke("summary") %>%
    invoke("residuals") %>%
    sdf_read_column("residuals")
}

reorder_first <- function(vector, name) {
  if (is.null(vector))
    return(vector)

  nm <- names(vector)
  if (is.null(nm) || !name %in% nm)
    return(vector)

  ordered <- c(name, base::setdiff(nm, name))
  vector[ordered]
}

intercept_first <- function(vector) {
  reorder_first(vector, "(Intercept)")
}

read_spark_vector <- function(jobj, field) {
  object <- invoke(jobj, field)
  invoke(object, "toArray")
}

read_spark_matrix <- function(jobj, field) {
  object <- invoke(jobj, field)
  nrow <- invoke(object, "numRows")
  ncol <- invoke(object, "numCols")
  data <- invoke(object, "toArray")
  matrix(data, nrow = nrow, ncol = ncol)
}
