scatters_vol_lh <- function(region) {
  
  library(tidyverse)
  library(openxlsx)
  
  #importing ages and sex
  T_1.5 <- read.csv("C:/Users/Victor/Documents/Universitaeten/TEC/Clínicas/8° trimestre/Profesor TEC/Caraza/volumetria/volumetry/batch_1/PPMI_T1_controls_1.5T_9_10_2020.csv")
  T_3 <- read.csv("C:/Users/Victor/Documents/Universitaeten/TEC/Clínicas/8° trimestre/Profesor TEC/Caraza/volumetria/volumetry/batch_1/PPMI_T1_controls_3T_9_10_2020.csv")
  batch0 <- read.xlsx("C:/Users/Victor/Documents/Universitaeten/TEC/Clínicas/8° trimestre/Profesor TEC/Caraza/volumetria/volumetry/MRI_subjects_processed_data2.xlsx",'Sheet1')
  
  #lh volumes of batch 0
  batch0_lh <- as.data.frame(read_tsv("C:/Users/Victor/Documents/Universitaeten/TEC/Clínicas/8° trimestre/Profesor TEC/Caraza/volumetria/volumetry/lhaparc_ICBM.txt"))
  batch0_lh$lh.aparc.volume <- substr(batch0_lh$lh.aparc.volume,61,63)
  colnames(batch0_lh)[1] <- "Num"
  colnames(batch0_lh) <- str_replace_all(colnames(batch0_lh),"-","_")
  colnames(batch0_lh) <- str_replace_all(colnames(batch0_lh),"3","thi")
  colnames(batch0_lh) <- str_replace_all(colnames(batch0_lh),"4","four")
  colnames(batch0_lh) <- str_replace_all(colnames(batch0_lh),"5","fif")
  batch0_withage <- merge(batch0_lh[, c("Num",region)],
                          batch0[, c("Num", "Age")])
  #p <- ggplot(batch0_withage, aes(x=Age,y=`Left_Lateral_Ventricle`))
  #p + geom_point()
  
  #lh volumes of batch 1 folder 1
  folder1_lh <- as.data.frame(read_tsv("C:/Users/Victor/Documents/Universitaeten/TEC/Clínicas/8° trimestre/Profesor TEC/Caraza/volumetria/volumetry/batch_1/folder_1/lhaparc_vol_2020-09-25_1732.txt"))
  folder1_lh$lh.aparc.volume <- substr(folder1_lh$lh.aparc.volume,6,9)
  colnames(folder1_lh)[1] <- "Subject"
  colnames(folder1_lh) <- str_replace_all(colnames(folder1_lh),"-","_")
  colnames(folder1_lh) <- str_replace_all(colnames(folder1_lh),"3","thi")
  colnames(folder1_lh) <- str_replace_all(colnames(folder1_lh),"4","four")
  colnames(folder1_lh) <- str_replace_all(colnames(folder1_lh),"5","fif")
  T_combined <- rbind(T_1.5,T_3)
  folder1_withage <- merge(folder1_lh[, c("Subject",region)],
                           T_combined[, c("Subject", "Age")])
  
  #lh volumes of batch 1 folder 2
  folder2_lh <- as.data.frame(read_tsv("C:/Users/Victor/Documents/Universitaeten/TEC/Clínicas/8° trimestre/Profesor TEC/Caraza/volumetria/volumetry/batch_1/folder_2/lhaparc_vol_2020-09-26_1111.txt"))
  folder2_lh$lh.aparc.volume <- substr(folder2_lh$lh.aparc.volume,6,9)
  colnames(folder2_lh)[1] <- "Subject"
  colnames(folder2_lh) <- str_replace_all(colnames(folder2_lh),"-","_")
  colnames(folder2_lh) <- str_replace_all(colnames(folder2_lh),"3","thi")
  colnames(folder2_lh) <- str_replace_all(colnames(folder2_lh),"4","four")
  colnames(folder2_lh) <- str_replace_all(colnames(folder2_lh),"5","fif")
  folder2_withage <- merge(folder2_lh[, c("Subject",region)],
                           T_combined[, c("Subject", "Age")])
  
  
  region_volumes <- rbind(batch0_withage[,2:3],folder1_withage[,2:3],folder2_withage[,2:3])
  p <- ggplot(region_volumes, aes_string(x="Age",y=region))
  p <- p + geom_point()
  print(p)
  ggsave(p, file=paste('C:/Users/Victor/Documents/Universitaeten/TEC/Clínicas/8° trimestre/Profesor TEC/Caraza/volumetria/volumetry/plots_vol_lh/',region, ".jpeg", sep=''), scale=2)
}

batch0_lh <- as.data.frame(read_tsv("C:/Users/Victor/Documents/Universitaeten/TEC/Clínicas/8° trimestre/Profesor TEC/Caraza/volumetria/volumetry/lhaparc_ICBM.txt"))
batch0_lh$lh.aparc.volume <- substr(batch0_lh$lh.aparc.volume,61,63)
colnames(batch0_lh)[1] <- "Num"
colnames(batch0_lh) <- str_replace_all(colnames(batch0_lh),"-","_")
colnames(batch0_lh) <- str_replace_all(colnames(batch0_lh),"3","thi")
colnames(batch0_lh) <- str_replace_all(colnames(batch0_lh),"4","four")
colnames(batch0_lh) <- str_replace_all(colnames(batch0_lh),"5","fif")
regions <- colnames(batch0_lh)

for (i in regions[2:37]) {
  scatters_vol_lh(i)
}
