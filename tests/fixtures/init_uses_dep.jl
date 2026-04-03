@use "./dep" double

initialized = Ref(false)
dep_result = Ref(0)

__init__() = begin
  initialized[] = true
  dep_result[] = double(21)
end
